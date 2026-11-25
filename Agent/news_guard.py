"""News guard: pauses a bot around scheduled HIGH-importance releases of the currencies its symbol depends on.

It writes halt_from_utc / halt_until_utc into the bot's profile file. The EA treats that window like a blackout (no new
setups, resting limits cancelled) and only accepts windows <= 6 h long starting <= 12 h ahead, so the Agent can stop a bot
briefly but can never make it trade more or take more risk.
Instant shocks that are NOT scheduled (flash moves) are handled inside the EA (shock guard + spread gates).
"""
import datetime as dt, json

CCY = {"XAU": ["USD"], "XAG": ["USD"], "USTEC": ["USD"], "US500": ["USD"], "US30": ["USD"], "BTC": ["USD"], "ETH": ["USD"],
       "USOIL": ["USD"], "UKOIL": ["USD"], "DE30": ["EUR"], "UK100": ["GBP"], "EURUSD": ["EUR", "USD"], "GBPUSD": ["GBP", "USD"],
       "USDJPY": ["USD", "JPY"]}
LEAD_MIN, LAG_MIN, MERGE_MIN = 20, 30, 40
_cache = {}


def currencies(symbol):
    for k, v in CCY.items():
        if symbol.upper().startswith(k) or k in symbol.upper(): return v
    return ["USD"]


def high_ids(mt5, ccy):
    if ccy not in _cache:
        ev = mt5.call("economic_calendar_list_events_by_currency", {"currency_code": ccy}).get("events", [])
        _cache[ccy] = {e["id"]: e["name"] for e in ev if e.get("importance") == "High importance"}
    return _cache[ccy]


def upcoming(mt5, symbol, now, hours=24):
    """-> sorted [(datetime, name)] of high-impact releases in the next `hours` (calendar time = server time = UTC on Exness)."""
    ids = {}
    for c in currencies(symbol): ids.update(high_ids(mt5, c))
    f = now.strftime("%Y-%m-%dT%H:%M:%S"); t = (now + dt.timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%S")
    vals = mt5.call("economic_calendar_list_values", {"datetime_from": f, "datetime_to": t, "limit": 1000}).get("values", [])
    out = [(dt.datetime.strptime(v["time"], "%Y-%m-%dT%H:%M:%S"), ids[v["event_id"]]) for v in vals if v["event_id"] in ids and not v.get("time_unknown")]
    return sorted(out)


def next_window(events, now):
    """Merge releases closer than MERGE_MIN, return (from, until, names) of the first window not yet over, or None."""
    wins = []
    for t, name in events:
        a, b = t - dt.timedelta(minutes=LEAD_MIN), t + dt.timedelta(minutes=LAG_MIN)
        if wins and a <= wins[-1][1] + dt.timedelta(minutes=MERGE_MIN - LEAD_MIN - LAG_MIN):
            wins[-1] = (wins[-1][0], max(wins[-1][1], b), wins[-1][2] + [name])
        else:
            wins.append((a, b, [name]))
    for a, b, names in wins:
        if b > now and (b - a) <= dt.timedelta(hours=6): return a, b, names
    return None
