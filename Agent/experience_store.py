"""Experience Store: under regime X with config Y we got Z, with recency decay (old evidence counts less)."""
import json, os, time

PATH = os.path.join(os.path.dirname(__file__), "experience.jsonl")


def add(asset, regime, confidence, config, exp_r, n_trades, max_dd_r, note="", start="", end=None):
    rec = {"t": time.time(), "from": start, "to": end or time.strftime("%Y-%m-%d"), "asset": asset, "regime": regime,
           "conf": confidence, "config": config, "exp_r": exp_r, "n": n_trades, "dd_r": max_dd_r, "note": note}
    with open(PATH, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")


def query(regime=None, asset=None, half_life_days=90):
    if not os.path.exists(PATH):
        return []
    out = []
    for ln in open(PATH, encoding="utf-8"):
        r = json.loads(ln)
        if (regime and r["regime"] != regime) or (asset and r["asset"] != asset):
            continue
        r["weight"] = r["conf"] * 0.5 ** ((time.time() - r["t"]) / 86400 / half_life_days)
        out.append(r)
    return sorted(out, key=lambda r: -r["weight"])
