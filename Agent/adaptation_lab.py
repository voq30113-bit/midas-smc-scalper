"""Adaptation lab: can the Agent adapt to changing market phases?

Idea: a trade journal from a full-period backtest tells what a config WOULD have done in any sub-window (R per trade is
independent of position size). So with several configs run over the same history we can replay the Agent's decisions
phase by phase using ONLY information available at each phase start, and compare against fixed configs.

  python adaptation_lab.py SYMBOL  name=journal.csv[,journal2.csv] name2=...  [--phase quarter|half|month] [--csv price.csv]

Phases = calendar quarters by default. A regime label per phase is derived from price (trendiness and volatility); the
Agent predicts the NEXT phase's regime as 'same as the last observed one' (honest persistence forecast).

Policies (all causal):
  fixed:<cfg>   always the same config (the baselines)
  oracle        best config of every phase in hindsight (upper bound, not achievable)
  follow        config that did best in the previous phase (needs >= MIN_N trades, else default)
  experience    config with the best recency-weighted expectancy in earlier phases of the same regime as the last one
  gate          default config, but PAUSED while the trailing expectancy of its shadow trades is < GATE_X (health gate / kill rule)
  ensemble      equal weight over all configs (diversification)
"""
import csv, collections, datetime as dt, json, os, sys, math

MIN_N = 10
GATE_X = -0.03          # pause when the last 2 phases' expectancy (R/trade) is below this
GATE_LOOKBACK = 2
HALF_LIFE = 4           # phases


def phase_of(t, kind):
    d = dt.datetime.strptime(t[:10], "%Y-%m-%d")
    if kind == "month": return f"{d.year}-{d.month:02d}"
    if kind == "half": return f"{d.year}H{1 if d.month <= 6 else 2}"
    return f"{d.year}Q{(d.month - 1) // 3 + 1}"


def load_cfg(paths):
    rows = []
    for p in paths:
        side = None
        if p.endswith("#L") or p.endswith("#S"): side, p = p[-1], p[:-2]      # path#L / path#S = that side's trades only
        for r in csv.DictReader(open(p, newline="", encoding="utf-8")):
            if side and r["dir"] != side: continue
            rows.append((r["close_utc"], float(r["pnl_r"])))
    rows.sort()
    return rows


def regimes_from_price(path, kind, step=1440):
    """Per-phase regime from a Dukascopy M1 CSV (date,time,o,h,l,c,...). Streams the file, keeps daily closes/ranges."""
    days = collections.OrderedDict()
    for ln in open(path, encoding="utf-8"):
        p = ln.split(",")
        if len(p) < 6: continue
        d = p[0].replace(".", "-"); h, l, c = float(p[3]), float(p[4]), float(p[5])
        x = days.get(d)
        if x is None: days[d] = [c, h, l, c]                      # first close, high, low, last close
        else:
            x[1] = max(x[1], h); x[2] = min(x[2], l); x[3] = c
    ph = collections.OrderedDict()
    for d, (c0, h, l, c1) in days.items():
        ph.setdefault(phase_of(d, kind), []).append((c0, h, l, c1))
    feat = {}
    for k, ds in ph.items():
        if len(ds) < 5: continue
        ret = (ds[-1][3] - ds[0][0]) / ds[0][0]
        path_len = sum(abs(d[3] - d[0]) / d[0] for d in ds) or 1e-9
        eff = abs(ret) / path_len
        rng = sum((d[1] - d[2]) / d[0] for d in ds) / len(ds)
        feat[k] = (ret, eff, rng)
    effs = sorted(f[1] for f in feat.values()); rngs = sorted(f[2] for f in feat.values())
    e_med = effs[len(effs) // 2]; r_lo, r_hi = rngs[len(rngs) // 3], rngs[2 * len(rngs) // 3]
    lab = {}
    for k, (ret, eff, rng) in feat.items():
        trend = ("UP" if ret > 0 else "DOWN") if eff >= e_med else "RANGE"
        vol = "HIGHVOL" if rng >= r_hi else ("LOWVOL" if rng <= r_lo else "MIDVOL")
        lab[k] = f"{trend}/{vol}"
    return lab


def summarize(rs):
    n = len(rs)
    if not n: return {"n": 0, "R": 0, "exp": 0, "pf": 0, "dd": 0, "win": 0}
    gp = sum(r for r in rs if r > 0); gl = -sum(r for r in rs if r < 0)
    eq = pk = dd = 0
    for r in rs:
        eq += r; pk = max(pk, eq); dd = max(dd, pk - eq)
    return {"n": n, "R": round(sum(rs), 1), "exp": round(sum(rs) / n, 3), "pf": round(gp / gl, 2) if gl else 99, "dd": round(dd, 1), "win": round(sum(1 for r in rs if r > 0) / n * 100)}


def run(sym, cfgs, kind="quarter", price=None):
    trades = {k: load_cfg(v) for k, v in cfgs.items()}
    phases = sorted({phase_of(t, kind) for v in trades.values() for t, _ in v})
    by = {k: collections.defaultdict(list) for k in cfgs}
    for k, v in trades.items():
        for t, r in v: by[k][phase_of(t, kind)].append(r)
    reg = regimes_from_price(price, kind) if price and os.path.exists(price) else {}
    names = list(cfgs); default = names[0]
    pol = collections.defaultdict(list); chosen = []
    paused_hist = collections.defaultdict(list)
    for i, ph in enumerate(phases):
        prev = phases[:i]
        # --- fixed baselines
        for k in names: pol["fixed:" + k] += by[k].get(ph, [])
        # --- oracle (hindsight)
        best = max(names, key=lambda k: sum(by[k].get(ph, [])))
        pol["oracle"] += by[best].get(ph, [])
        # --- follow the last winner
        pick = default
        if prev:
            cand = [k for k in names if len(by[k].get(prev[-1], [])) >= MIN_N]
            if cand: pick = max(cand, key=lambda k: sum(by[k][prev[-1]]) / len(by[k][prev[-1]]))
        pol["follow"] += by[pick].get(ph, [])
        # --- regime experience
        pick_e = default; why = "default"
        if prev and reg:
            lastlab = reg.get(prev[-1]); score = {}
            for k in names:
                num = den = 0
                for j, pj in enumerate(prev):
                    if reg.get(pj) != lastlab: continue
                    rs = by[k].get(pj, [])
                    if len(rs) < MIN_N: continue
                    w = 0.5 ** ((len(prev) - 1 - j) / HALF_LIFE)
                    num += w * sum(rs); den += w * len(rs)
                if den: score[k] = num / den
            if score:
                pick_e = max(score, key=score.get); why = f"{lastlab}"
        pol["experience"] += by[pick_e].get(ph, [])
        # --- health gate on the default config (shadow tracking continues while paused)
        recent = [r for pj in prev[-GATE_LOOKBACK:] for r in by[default].get(pj, [])]
        paused = bool(recent) and len(recent) >= MIN_N and sum(recent) / len(recent) < GATE_X
        if not paused: pol["gate"] += by[default].get(ph, [])
        paused_hist["gate"].append(paused)
        # --- ensemble (equal weight: average each config's R per trade slice)
        ens = []
        for k in names:
            ens += [r / len(names) for r in by[k].get(ph, [])]
        pol["ensemble"] += ens
        chosen.append({"phase": ph, "regime": reg.get(ph), "follow": pick, "experience": pick_e, "experience_basis": why, "gate_paused": paused, "oracle": best,
                       "default_exp": round(sum(by[default].get(ph, [])) / max(1, len(by[default].get(ph, []))), 3), "default_n": len(by[default].get(ph, []))})
    out = {"symbol": sym, "phase_kind": kind, "default": default, "policies": {k: summarize(v) for k, v in pol.items()}, "phases": chosen}
    return out


def main():
    a = [x for x in sys.argv[1:] if not x.startswith("--")]
    kind = sys.argv[sys.argv.index("--phase") + 1] if "--phase" in sys.argv else "quarter"
    price = sys.argv[sys.argv.index("--csv") + 1] if "--csv" in sys.argv else None
    if price: a = [x for x in a if x != price]
    if kind in a: a.remove(kind)
    sym = a[0]; cfgs = {}
    for kv in a[1:]:
        k, v = kv.split("=", 1); cfgs[k] = v.split(",")
    res = run(sym, cfgs, kind, price)
    print(f"\n{sym}  phases={kind}  default={res['default']}")
    print(f"{'policy':26}{'n':>6}{'totR':>8}{'exp/R':>8}{'PF':>6}{'maxDD R':>9}{'win%':>6}")
    for k, v in sorted(res["policies"].items(), key=lambda x: -x[1]["R"]):
        print(f"{k:26}{v['n']:>6}{v['R']:>8}{v['exp']:>8}{v['pf']:>6}{v['dd']:>9}{v['win']:>6}")
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "backtests", f"adaptation_{sym}_{kind}.json")
    json.dump(res, open(out, "w"), indent=1)
    print("written", os.path.abspath(out))


if __name__ == "__main__":
    main()
