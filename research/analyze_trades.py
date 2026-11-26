"""Where the sweep engine's trades make and lose money (final config, Exness M1 + Dukascopy gold)."""
import csv, os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "backtests")
SETS = {"gold family (Exness)": ["final_xau_exness_m1", "e_XAUEUR_F", "e_XAUGBP_F"], "gold Duka 2021-26": ["final_xau_duka_full"],
        "indices (Exness)": ["scan_US30", "scan_US500", "scan_UK100", "scan_JP225", "scan_USTEC"]}


def load(names):
    out = []
    for n in names:
        p = os.path.join(ROOT, n + "_journal.csv")
        if os.path.exists(p):
            out += list(csv.DictReader(open(p, encoding="utf-8")))
    return out


def line(label, rows):
    r = [float(x["pnl_r"]) for x in rows]
    if not r:
        return
    gl = -sum(v for v in r if v < 0)
    mfe = sum(float(x["mfe_r"]) for x in rows) / len(r)
    print(f"   {label:14} n={len(r):4d} exp={sum(r)/len(r):+.2f}R win={100*sum(v>0 for v in r)/len(r):3.0f}% PF={(sum(v for v in r if v>0)/gl) if gl else 99:5.2f} avgMFE={mfe:.2f}")


for title, names in SETS.items():
    rows = load(names)
    print(f"\n## {title}")
    line("ALL", rows)
    for key in ("dir", "exit", "tag", "htf", "vol_regime", "trend_regime"):
        print(f"  by {key}")
        for v in sorted({x.get(key, "") for x in rows}):
            line(v, [x for x in rows if x.get(key, "") == v])
    print("  by hour block (profile clock)")
    for lo, hi in ((0, 10), (10, 13), (13, 16), (16, 24)):
        line(f"{lo:02d}-{hi:02d}", [x for x in rows if lo <= int(x["clock_hour"]) < hi])
    print("  by hold minutes")
    for lo, hi in ((0, 15), (15, 60), (60, 240), (240, 10**6)):
        line(f"{lo}-{hi}", [x for x in rows if lo <= float(x["hold_min"]) < hi])
    full = [x for x in rows if float(x["pnl_r"]) <= -0.9]
    print(f"  full losers: {len(full)}; of them reached +0.5R first: {sum(float(x['mfe_r'])>=0.5 for x in full)}, +1R first: {sum(float(x['mfe_r'])>=1 for x in full)}")
    mf = sorted(float(x["mfe_r"]) for x in rows)
    print("  MFE share >= 1R/2R/3R/5R:", [round(sum(v >= k for v in mf) / len(mf), 2) for k in (1, 2, 3, 5)])
