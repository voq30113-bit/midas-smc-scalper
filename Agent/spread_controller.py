"""Spread controller: keeps each bot's spread gates matched to the spread the market is ACTUALLY quoting.

The EA skips a setup when spread > max_spread_atr x ATR (market-level) or > max_spread_r_pct of that trade's R.
Spreads are not constant across years (the owner observed they are far wider than 2-3 years ago), so fixed limits
are either too loose (a news spike gets through) or too tight (every trade rejected). The limit is therefore a multiple
of the recent TYPICAL spread/ATR ratio: normal fluctuation passes, a spread several times typical is a shock and is blocked.
"""
import statistics

K_NORMAL = 5.0            # allowed spread = K x the typical spread/ATR
ATR_RANGE = (0.10, 0.45)  # EA hard range is 0.05-1.0
RPCT_RANGE = (10.0, 25.0)  # EA hard range is 3-50
TYPICAL_STOP_ATR = 1.4    # median stop observed in the journals (x ATR)


def _atr_series(bars, n=14):
    tr, prev = [], None
    for b in bars:
        t = (b["high"] - b["low"]) if prev is None else max(b["high"] - b["low"], abs(b["high"] - prev), abs(b["low"] - prev))
        tr.append(t); prev = b["close"]
    return [None] * n + [sum(tr[i - n:i]) / n for i in range(n, len(tr))]


def ratios(bars, point):
    atr = _atr_series(bars)
    return [(b["spread"] * point) / a for b, a in zip(bars, atr) if a and b.get("spread", 0) > 0]


def analyse(mt5, symbol, now, days=20):
    import datetime as dt
    f = (now - dt.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%S"); t = now.strftime("%Y-%m-%dT%H:%M:%S")
    bars = mt5.bars(symbol, "M5", f, t)
    info = mt5.info(symbol)
    point = info["point"]
    r = ratios(bars, point)
    if len(r) < 500:
        return None
    r.sort()
    med = statistics.median(r)
    recent = statistics.median(ratios(bars[-1440:], point) or [med])        # ~5 days
    cur = None
    if info.get("ask") and info.get("bid") and bars:
        a = _atr_series(bars)[-1]
        cur = (info["ask"] - info["bid"]) / a if a else None
    prop_atr = round(min(ATR_RANGE[1], max(ATR_RANGE[0], med * K_NORMAL)), 3)
    prop_r = round(min(RPCT_RANGE[1], max(RPCT_RANGE[0], med / TYPICAL_STOP_ATR * 100 * K_NORMAL)), 1)
    return {"median_ratio": round(med, 4), "p95_ratio": round(r[int(len(r) * .95)], 4), "recent5d_ratio": round(recent, 4),
            "current_ratio": round(cur, 4) if cur else None, "elevated": recent > med * 1.5,
            "proposed_max_spread_atr": prop_atr, "proposed_max_spread_r_pct": prop_r, "bars": len(bars)}
