"""MIDAS Agent - phase 1 (observe) + LEVEL-1 AUTHORITY the owner delegated: spread gates and news pauses only.

Each cycle it
  1. pulls H1 bars of every bot's symbol from MT5 (read-only) and labels the market regime (rule-based + hysteresis),
  2. reads the EA journals and checks each bot's health (expectancy of recent trades vs before),
  3. makes a decision (today only: hold / alert) with a reason, appended to a hash-chained log,
  4. writes agent_state.json, which publish_performance.py ships (encrypted) to the control page.

What it MAY change (through Parameter Manager + tools/profile_gateway.py, every change logged with old -> new and why):
  - max_spread_atr / max_spread_r_pct  (matched to the spread the market actually quotes, see spread_controller.py)
  - halt_from_utc / halt_until_utc      (pause around scheduled high-impact news, see news_guard.py)
It cannot touch risk %, floors, magic or engine logic, and it never sends an order. Switching profiles (phase 2) is not enabled.

    python agent.py              # one cycle
    python agent.py --loop 30    # every 30 minutes
"""
import hashlib, json, os, sys, time, datetime
import sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import performance_analyzer as pa
import parameter_manager as pm, spread_controller as sc, news_guard as ng
import profile_gateway as gw
import decision_engine as de
import regime_detector as rd

HERE = os.path.dirname(__file__)
STATE = os.path.join(HERE, "agent_state.json")
LOG = os.path.join(HERE, "decisions.jsonl")
BOTS = [{"symbol": "XAUUSD", "group": "gold"}, {"symbol": "XAUEUR", "group": "gold"}, {"symbol": "XAUGBP", "group": "gold"}]          # only the validated bot; add symbols here after they pass out-of-sample on Exness


def adx_atr(bars):
    """Wilder ADX(14) and ATR(14) on a list of OHLC dicts; returns (adx, atr_ratio_vs_last_60, above_sma200)."""
    h = [b["high"] for b in bars]; l = [b["low"] for b in bars]; c = [b["close"] for b in bars]
    n = 14
    if len(c) < 230: return None
    tr, pdm, mdm = [], [], []
    for i in range(1, len(c)):
        tr.append(max(h[i] - l[i], abs(h[i] - c[i - 1]), abs(l[i] - c[i - 1])))
        up, dn = h[i] - h[i - 1], l[i - 1] - l[i]
        pdm.append(up if up > dn and up > 0 else 0.0); mdm.append(dn if dn > up and dn > 0 else 0.0)
    def wilder(x):
        out = [sum(x[:n])]
        for v in x[n:]: out.append(out[-1] - out[-1] / n + v)
        return out
    atr_s, p_s, m_s = wilder(tr), wilder(pdm), wilder(mdm)
    dx = []
    for a, p, m in zip(atr_s, p_s, m_s):
        pdi, mdi = (100 * p / a if a else 0), (100 * m / a if a else 0)
        dx.append(100 * abs(pdi - mdi) / (pdi + mdi) if pdi + mdi else 0)
    adx = sum(dx[:n]) / n
    for v in dx[n:]: adx = (adx * (n - 1) + v) / n
    atr = [a / n for a in atr_s]
    ratio = atr[-1] / (sum(atr[-60:]) / 60)
    return adx, ratio, c[-1] > sum(c[-200:]) / 200


def append_log(rec):
    prev = "GENESIS"
    if os.path.exists(LOG):
        lines = open(LOG, encoding="utf-8").read().strip().splitlines()
        if lines: prev = json.loads(lines[-1])["hash"]
    rec["prev"] = prev
    rec["hash"] = hashlib.sha256((prev + json.dumps(rec, sort_keys=True)).encode()).hexdigest()
    with open(LOG, "a", encoding="utf-8") as f: f.write(json.dumps(rec) + "\n")


def manage(mt5, bot, state, now):
    """Level-1 actions for one bot. Each action is validated by the Parameter Manager and logged."""
    sym = bot["symbol"]; cur = gw.read(gw.path(sym))
    pm._last.update({tuple(k.split("|", 1)): v for k, v in state.get("last_change", {}).items()})
    try:
        a = sc.analyse(mt5, sym, now)
    except Exception as e:
        a = None; print(sym, "spread analysis failed:", e)
    if a:
        state.setdefault("spread", {})[sym] = {**a, "updated_utc": now.strftime("%Y-%m-%d %H:%M:%S")}
        changes = {}
        for key, prop in (("max_spread_atr", a["proposed_max_spread_atr"]), ("max_spread_r_pct", a["proposed_max_spread_r_pct"])):
            current = float(cur.get(key, 0.25 if key == "max_spread_atr" else 15.0))
            if abs(prop - current) / current < 0.05: continue                        # not worth a change
            ok, val, why = pm.check(sym, key, current, prop, now.timestamp())
            if ok:
                changes[key] = round(val, 3); state.setdefault("last_change", {})[f"{sym}|{key}"] = now.timestamp()
                append_log({"t": now.isoformat(), "bot": sym, "type": "tune", "reason": f"{key} {current} -> {round(val, 3)} (typical spread {a['median_ratio']:.3f} ATR, recent 5d {a['recent5d_ratio']:.3f}; proposed {prop}) {'; '.join(why)}"})
        if changes: gw.update(sym, changes)
        if a["elevated"]:
            append_log({"t": now.isoformat(), "bot": sym, "type": "alert", "reason": f"spread elevated: last 5d {a['recent5d_ratio']:.3f} ATR vs 20d {a['median_ratio']:.3f}"}) if not state.get("spread_alerted", {}).get(sym) else None
        state.setdefault("spread_alerted", {})[sym] = bool(a["elevated"])
    try:
        nown = now.replace(tzinfo=None)            # calendar times are server time = UTC on Exness
        ev = ng.upcoming(mt5, sym, nown)
        win = ng.next_window(ev, nown)
    except Exception as e:
        win = None; print(sym, "news lookup failed:", e)
        return
    want = ({"halt_from_utc": win[0].strftime("%Y-%m-%d %H:%M"), "halt_until_utc": win[1].strftime("%Y-%m-%d %H:%M")} if win else None)
    have = {k: cur.get(k) for k in ("halt_from_utc", "halt_until_utc") if cur.get(k)}
    state.setdefault("news", {})[sym] = {"next": [(t.strftime("%Y-%m-%d %H:%M"), n) for t, n in ev[:5]], "window": [x.strftime("%Y-%m-%d %H:%M") for x in win[:2]] if win else None}
    if want and have != want:
        gw.update(sym, want)
        append_log({"t": now.isoformat(), "bot": sym, "type": "pause", "reason": f"halt {want['halt_from_utc']} -> {want['halt_until_utc']} UTC around: {'; '.join(win[2])[:160]}"})
    elif not want and have:
        gw.update(sym, {}, remove=("halt_from_utc", "halt_until_utc"))


def cycle():
    state = json.load(open(STATE, encoding="utf-8")) if os.path.exists(STATE) else {"regimes": {}, "hyst": {}}
    now = datetime.datetime.now(datetime.timezone.utc)
    rows = pa.load(); health = pa.health(rows)
    try:
        import mt5_client; mt5 = mt5_client.MT5()
    except Exception as e:
        mt5 = None; print("MT5 not reachable, regime skipped:", e)
    for b in BOTS:
        sym = b["symbol"]
        if mt5: manage(mt5, b, state, now)
    for b in BOTS:
        sym = b["symbol"]; regime = state["regimes"].get(sym, {}).get("regime", "UNKNOWN")
        if mt5:
            try:
                bars = mt5.bars(sym, "H1", (now - datetime.timedelta(days=40)).strftime("%Y-%m-%dT%H:%M:%S"), now.strftime("%Y-%m-%dT%H:%M:%S"))
                m = adx_atr(bars)
                if m:
                    hs = state["hyst"].get(sym, {}); st = rd.RegimeState(hs.get("current"), hs.get("cand"), hs.get("count", 0))
                    regime, conf, changed = rd.step(st, m[0], m[1], m[2], b["group"])
                    state["hyst"][sym] = {"current": st.current, "cand": st.cand, "count": st.count}
                    old = state["regimes"].get(sym, {}).get("regime")
                    state["regimes"][sym] = {"regime": regime, "confidence": round(conf, 2), "adx": round(m[0], 1), "atr_ratio": round(m[1], 2), "above_ma200": m[2], "bars": len(bars), "updated_utc": now.strftime("%Y-%m-%d %H:%M:%S")}
                    if changed and old and old != regime:
                        append_log({"t": now.isoformat(), "bot": sym, "type": "alert", "reason": f"regime changed {old} -> {regime} (conf {conf:.2f})"})
            except Exception as e:
                print(sym, "regime failed:", e)
        h = health.get(sym, {"status": "insufficient", "n": 0})
        d = de.decide(sym, regime, h, [])
        state.setdefault("health", {})[sym] = h
        if d.type != "hold":
            append_log({"t": now.isoformat(), "bot": sym, "type": d.type, "reason": d.reason})
    state["updated_utc"] = now.strftime("%Y-%m-%d %H:%M:%S"); state["phase"] = 1; state["mode"] = "observe-only"
    json.dump(state, open(STATE, "w", encoding="utf-8"), indent=1)
    print(json.dumps({s: v.get("regime") for s, v in state["regimes"].items()}))


if __name__ == "__main__":
    if "--loop" in sys.argv:
        mins = int(sys.argv[sys.argv.index("--loop") + 1])
        while True:
            cycle(); time.sleep(mins * 60)
    else:
        cycle()
