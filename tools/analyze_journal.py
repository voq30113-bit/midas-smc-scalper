#!/usr/bin/env python3
"""
MIDAS v4 - trade-journal analyzer.

Reads the CSV(s) the EA writes to  <Common>\\Files\\MIDAS\\journal_<SYMBOL>_<magic>[_TEST].csv
and prints performance per symbol and per regime (the "Regime x Config -> Performance"
table the Agent's Performance Analyzer needs).

    python analyze_journal.py                      # every journal in the Common\\Files\\MIDAS folder
    python analyze_journal.py path\\to\\a.csv b.csv   # explicit files
    python analyze_journal.py --test               # only *_TEST.csv (strategy-tester output)
    python analyze_journal.py --json out.json      # also dump the numbers

Only needs the standard library.
"""
import csv, glob, json, os, sys
from collections import defaultdict

COMMON = os.path.join(os.environ.get("APPDATA", ""), "MetaQuotes", "Terminal", "Common", "Files", "MIDAS")


def load(paths):
    rows = []
    for p in paths:
        with open(p, newline="", encoding="utf-8", errors="replace") as f:
            for r in csv.DictReader(f):
                try:
                    r["pnl_money"] = float(r["pnl_money"]); r["pnl_r"] = float(r["pnl_r"])
                    r["mfe_r"] = float(r["mfe_r"]); r["mae_r"] = float(r["mae_r"])
                    r["hold_min"] = float(r["hold_min"]); r["r_atr"] = float(r["r_atr"])
                    r["spread_r_pct"] = float(r["spread_r_pct"])
                except (KeyError, ValueError):
                    continue
                r["_file"] = os.path.basename(p)
                rows.append(r)
    return rows


def stats(rs):
    n = len(rs)
    if n == 0:
        return None
    w = [r for r in rs if r["pnl_r"] > 0]
    l = [r for r in rs if r["pnl_r"] <= 0]
    gp = sum(r["pnl_money"] for r in rs if r["pnl_money"] > 0)
    gl = -sum(r["pnl_money"] for r in rs if r["pnl_money"] < 0)
    # max drawdown of the cumulative R curve (in R)
    eq = peak = dd = 0.0
    for r in sorted(rs, key=lambda x: x["close_utc"]):
        eq += r["pnl_r"]; peak = max(peak, eq); dd = max(dd, peak - eq)
    return {
        "n": n,
        "win_rate": len(w) / n * 100,
        "avg_win_r": (sum(r["pnl_r"] for r in w) / len(w)) if w else 0.0,
        "avg_loss_r": (sum(r["pnl_r"] for r in l) / len(l)) if l else 0.0,
        "expectancy_r": sum(r["pnl_r"] for r in rs) / n,
        "total_r": sum(r["pnl_r"] for r in rs),
        "profit_factor": (gp / gl) if gl > 0 else float("inf"),
        "net_money": sum(r["pnl_money"] for r in rs),
        "max_dd_r": dd,
        "avg_mfe_r": sum(r["mfe_r"] for r in rs) / n,
        "avg_mae_r": sum(r["mae_r"] for r in rs) / n,
        "avg_hold_min": sum(r["hold_min"] for r in rs) / n,
        "avg_stop_atr": sum(r["r_atr"] for r in rs) / n,
        "avg_spread_r_pct": sum(r["spread_r_pct"] for r in rs) / n,
    }


HDR = f"{'group':<26}{'n':>5}{'win%':>7}{'exp R':>8}{'totR':>8}{'PF':>6}{'maxDD R':>9}{'MFE':>6}{'MAE':>6}{'hold m':>8}{'stop ATR':>9}{'spr%R':>7}"


def line(name, s):
    if not s:
        return f"{name:<26}{'-':>5}"
    pf = "inf" if s["profit_factor"] == float("inf") else f"{s['profit_factor']:.2f}"
    return (f"{name:<26}{s['n']:>5}{s['win_rate']:>7.1f}{s['expectancy_r']:>8.2f}{s['total_r']:>8.1f}{pf:>6}"
            f"{s['max_dd_r']:>9.1f}{s['avg_mfe_r']:>6.2f}{s['avg_mae_r']:>6.2f}{s['avg_hold_min']:>8.0f}"
            f"{s['avg_stop_atr']:>9.2f}{s['avg_spread_r_pct']:>7.1f}")


def table(title, rows, key):
    print(f"\n== {title} ==")
    print(HDR)
    groups = defaultdict(list)
    for r in rows:
        groups[key(r)].append(r)
    out = {}
    for k in sorted(groups):
        s = stats(groups[k]); out[str(k)] = s
        print(line(str(k), s))
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    js = None
    if "--json" in sys.argv:
        js = sys.argv[sys.argv.index("--json") + 1]
        args = [a for a in args if a != js]
    paths = args or sorted(glob.glob(os.path.join(COMMON, "journal_*.csv")))
    if "--test" in sys.argv:
        paths = [p for p in paths if p.endswith("_TEST.csv")]
    if not paths:
        print("no journal files found in", COMMON); return
    rows = load(paths)
    if not rows:
        print("journals are empty"); return
    print(f"{len(rows)} trades from {len(paths)} file(s)")
    res = {"all": stats(rows)}
    print("\n" + HDR); print(line("ALL", res["all"]))
    res["symbol"] = table("per symbol", rows, lambda r: r["symbol"])
    res["setup"] = table("per setup tag", rows, lambda r: r["tag"].split("|")[-1])
    res["side"] = table("per side", rows, lambda r: r["dir"])
    res["vol_regime"] = table("per volatility regime (ATR vs its own last day)", rows, lambda r: r["vol_regime"])
    res["trend_regime"] = table("per HTF-trend relation", rows, lambda r: r["trend_regime"])
    res["symbol_x_vol"] = table("symbol x volatility regime", rows, lambda r: f"{r['symbol']}/{r['vol_regime']}")
    res["clock_hour"] = table("per hour on the profile clock", rows, lambda r: f"{int(r['clock_hour']):02d}h")
    res["exit"] = table("per exit type", rows, lambda r: r["exit"] + (" +TP1" if r["tp1"] == "1" else ""))
    if js:
        json.dump(res, open(js, "w"), indent=1, default=str)
        print("\nwritten", js)


if __name__ == "__main__":
    main()
