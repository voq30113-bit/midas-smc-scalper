#!/usr/bin/env python3
"""Rank a symbol scan: reads backtests/<prefix>*_report.json and *_journal.csv.

    python scan_report.py scan_            # default prefix

Per symbol: trades, PF, DD, expectancy in R, and the same split into two halves of the period (first half / second half),
because a symbol that only works in one half is a coincidence, not an edge. A symbol 'passes' when
n >= MIN_N, PF >= MIN_PF in the whole period AND in each half (PF of the R values), and expectancy > 0 in both halves.
Scanning many symbols guarantees some pass by luck: expect ~ (symbols x false-positive rate) lucky survivors, so survivors
still need an independent check (other period/source, real ticks) before they are traded.
"""
import csv, glob, json, os, sys

MIN_N, MIN_PF = 15, 1.5
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "backtests")


def pf_r(rs):
    gp = sum(r for r in rs if r > 0); gl = -sum(r for r in rs if r < 0)
    return gp / gl if gl else (99.0 if gp else 0.0)


def main():
    prefix = sys.argv[1] if len(sys.argv) > 1 else "scan_"
    rows = []
    for rp in sorted(glob.glob(os.path.join(ROOT, prefix + "*_report.json"))):
        name = os.path.basename(rp)[len(prefix):-len("_report.json")]
        try:
            rep = json.load(open(rp, encoding="utf-8"))
        except ValueError:
            continue
        jp = rp.replace("_report.json", "_journal.csv")
        rs = []
        if os.path.exists(jp):
            for r in csv.DictReader(open(jp, newline="", encoding="utf-8")):
                rs.append((r["close_utc"], float(r["pnl_r"])))
        rs.sort()
        n = len(rs)
        h1 = [r for _, r in rs[: n // 2]]; h2 = [r for _, r in rs[n // 2:]]
        rows.append({"sym": name, "n": rep.get("trades") or 0, "pf": rep.get("profit_factor") or 0, "dd": rep.get("drawdown_percent_equity") or 0,
                     "profit": rep.get("profit") or 0, "exp": (sum(r for _, r in rs) / n) if n else 0,
                     "pf1": pf_r(h1) if h1 else 0, "pf2": pf_r(h2) if h2 else 0,
                     "e1": (sum(h1) / len(h1)) if h1 else 0, "e2": (sum(h2) / len(h2)) if h2 else 0})
    rows.sort(key=lambda x: (-(x["n"] >= MIN_N), -x["pf"]))
    print(f"{'symbol':10}{'n':>5}{'PF':>7}{'DD%':>6}{'exp R':>7}{'PF 1st':>8}{'PF 2nd':>8}{'exp1':>7}{'exp2':>7}  verdict")
    passed = 0
    for x in rows:
        ok = x["n"] >= MIN_N and x["pf"] >= MIN_PF and x["pf1"] >= MIN_PF and x["pf2"] >= MIN_PF and x["e1"] > 0 and x["e2"] > 0
        passed += ok
        print(f"{x['sym']:10}{x['n']:>5}{x['pf']:>7.2f}{x['dd']:>6.1f}{x['exp']:>7.2f}{x['pf1']:>8.2f}{x['pf2']:>8.2f}{x['e1']:>7.2f}{x['e2']:>7.2f}  {'PASS' if ok else ('few trades' if x['n'] < MIN_N else '-')}")
    print(f"\n{len(rows)} symbols scanned, {passed} pass the screen. Lucky survivors are expected: validate each one independently.")


if __name__ == "__main__":
    main()
