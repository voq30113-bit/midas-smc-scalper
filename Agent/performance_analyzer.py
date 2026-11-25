"""Performance Analyzer: per (symbol, regime) health from the EA's journal CSV.
tools/analyze_journal.py has the full report."""
import csv, glob, os
from collections import defaultdict

COMMON = os.path.join(os.environ.get("APPDATA", ""), "MetaQuotes", "Terminal", "Common", "Files", "MIDAS")


def load(paths=None):
    rows = []
    for p in paths or glob.glob(os.path.join(COMMON, "journal_*.csv")):
        with open(p, newline="", encoding="utf-8", errors="replace") as f:
            for r in csv.DictReader(f):
                try:
                    r["pnl_r"] = float(r["pnl_r"]); r["pnl_money"] = float(r["pnl_money"])
                except (KeyError, ValueError):
                    continue
                rows.append(r)
    return sorted(rows, key=lambda r: r["close_utc"])


def expectancy(rs):
    return sum(r["pnl_r"] for r in rs) / len(rs) if rs else 0.0


def health(rows, recent=20, drop=0.3):
    """Flags symbols whose last `recent` trades are `drop` R worse than before. Needs >= 2*recent trades."""
    by = defaultdict(list)
    for r in rows:
        by[r["symbol"]].append(r)
    out = {}
    for s, rs in by.items():
        if len(rs) < 2 * recent:
            out[s] = {"status": "insufficient", "n": len(rs)}
            continue
        rec, old = expectancy(rs[-recent:]), expectancy(rs[:-recent])
        out[s] = {"status": "review" if old - rec > drop else "ok", "recent_r": rec, "before_r": old, "n": len(rs)}
    return out


def by_regime(rows):
    g = defaultdict(list)
    for r in rows:
        g[(r["symbol"], r["vol_regime"])].append(r)
    return {k: {"n": len(v), "exp_r": expectancy(v)} for k, v in g.items()}
