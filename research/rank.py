"""Ranks engine configs by how many data sets of a group are positive in both halves, then by pooled expectancy."""
import json, os
from engines import GROUPS

res = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "engines_results.json")))
G = dict(GROUPS); G["gold"] = GROUPS["gold"] + ["XAUUSD_DUKA"]
for g, syms in G.items():
    rows = []
    for cfg in res[syms[0]]:
        s = [res[y][cfg] for y in syms]
        n = sum(v["n"] for v in s)
        if n < 150:
            continue
        both = sum(v["e1"] > 0 and v["e2"] > 0 for v in s)
        exp = sum(v["exp"] * v["n"] for v in s) / n
        rows.append((both, exp, cfg, n, [f"{y}:{v['e1']:+.2f}/{v['e2']:+.2f}" for y, v in zip(syms, s)]))
    rows.sort(reverse=True)
    pos = sum(1 for r in rows if r[1] > 0)
    print(f"\n## {g}: {len(rows)} configs, {pos} with pooled exp>0   (cfg = signal|stopATR|trailATR|maxBars|tpR|volFilter)")
    for both, exp, cfg, n, d in rows[:8]:
        print(f"  {cfg:24} both-halves+ {both}/{len(syms)}  pooled {exp:+.3f}R  n={n}\n      {'  '.join(d)}")
