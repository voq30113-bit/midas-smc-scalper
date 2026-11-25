#!/usr/bin/env python3
"""
MIDAS v4 - profile gateway (the ONLY door through which Python / the Agent changes an EA).

The EA re-reads  <Common>\\Files\\MIDAS\\profile_<SYMBOL>.ini  every InpProfileReloadBars M5 bars
and acknowledges in  status_<SYMBOL>_<magic>.ini.  This script writes that file with the same
validation the EA applies (SAFE keys only, every value clamped), then waits for the ack.

    python profile_gateway.py show  XAUUSD
    python profile_gateway.py set   XAUUSD blackout1=16-18 max_spread_atr=0.2 --magic 580001
    python profile_gateway.py clear XAUUSD          # remove the override -> EA falls back to its preset

NOT settable here, on purpose (Critical class in the Agent design): risk %, capital floor,
daily loss, magic, engine logic. Those stay in the EA inputs / a human decision.
"""
import os, sys, time

COMMON = os.path.join(os.environ.get("APPDATA", ""), "MetaQuotes", "Terminal", "Common", "Files", "MIDAS")

# key -> (kind, lo, hi)
SAFE = {
    "profile": ("name", None, None),
    "clock": ("enum", ("NY7", "UTC", "EU"), None),
    "use_session": ("bool", None, None),
    "session": ("hours", None, None),
    "blackout1": ("hours", None, None),
    "blackout2": ("hours", None, None),
    "asia": ("hours", None, None),
    "weekend_flat": ("bool", None, None),
    "weekend_flat_hour": ("int", 0, 23),
    "max_trades_day": ("int", 1, 20),
    "max_spread_atr": ("float", 0.05, 1.0),
    "max_spread_r_pct": ("float", 3.0, 50.0),
    "max_sl_atr": ("float", 0.8, 4.0),
    "halt_from_utc": ("datetime", None, None),
    "halt_until_utc": ("datetime", None, None),
}
PROFILES = ("GOLD", "SILVER", "FX", "INDEX_US", "INDEX_EU", "OIL", "CRYPTO")


def validate(k, v):
    if k not in SAFE:
        raise SystemExit(f"key '{k}' is not an allowed (safe) key. Allowed: {', '.join(SAFE)}")
    kind, lo, hi = SAFE[k]
    if kind == "name":
        if v.upper() not in PROFILES: raise SystemExit(f"profile must be one of {PROFILES}")
        return v.upper()
    if kind == "enum":
        if v.upper() not in lo: raise SystemExit(f"{k} must be one of {lo}")
        return v.upper()
    if kind == "bool":
        return "1" if v.lower() in ("1", "true", "on", "yes") else "0"
    if kind == "hours":
        if v.lower() in ("off", "none"): return "off"
        a, b = v.split("-"); a, b = int(a), int(b)
        if not (0 <= a <= 24 and 0 <= b <= 24): raise SystemExit(f"{k}: hours must be 0..24")
        return f"{a}-{b}"
    if kind == "int":
        x = int(v); return str(max(lo, min(hi, x)))
    if kind == "datetime":
        import datetime as _dt
        _dt.datetime.strptime(v, "%Y-%m-%d %H:%M"); return v
    x = float(v); return str(max(lo, min(hi, x)))


def path(sym): return os.path.join(COMMON, f"profile_{sym}.ini")


def read(p):
    d = {}
    if os.path.exists(p):
        for ln in open(p, encoding="utf-8"):
            ln = ln.strip()
            if ln and ln[0] not in "#;" and "=" in ln:
                k, v = ln.split("=", 1); d[k.strip().lower()] = v.strip()
    return d


def update(sym, changes, remove=()):
    """Programmatic use by the Agent: validate, merge, write atomically. Returns the resulting dict."""
    os.makedirs(COMMON, exist_ok=True)
    p = path(sym); d = read(p)
    for k in remove: d.pop(k, None)
    for k, v in changes.items(): d[k.lower()] = validate(k.lower(), str(v))
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("# managed by the MIDAS Agent " + time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime()) + " UTC" + chr(10))
        for k, v in d.items(): f.write(f"{k}={v}" + chr(10))
    os.replace(tmp, p)
    return d


def main():
    if len(sys.argv) < 3: print(__doc__); return
    cmd, sym = sys.argv[1], sys.argv[2].upper()
    magic = None
    if "--magic" in sys.argv: magic = sys.argv[sys.argv.index("--magic") + 1]
    p = path(sym); os.makedirs(COMMON, exist_ok=True)
    if cmd == "show":
        print(read(p) or "(no override file - EA runs its built-in preset)")
        for f in sorted(os.listdir(COMMON)):
            if f.startswith(f"status_{sym}_"):
                print("\n-- " + f); print(open(os.path.join(COMMON, f), encoding="utf-8").read())
    elif cmd == "clear":
        if os.path.exists(p): os.remove(p); print("removed", p)
    elif cmd == "set":
        d = read(p)
        for kv in sys.argv[3:]:
            if kv.startswith("--") or kv == magic: continue
            k, v = kv.split("=", 1); k = k.lower()
            d[k] = validate(k, v)
        tmp = p + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(f"# written by profile_gateway.py {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
            for k, v in d.items(): f.write(f"{k}={v}\n")
        os.replace(tmp, p)
        print("written", p, d)
        if magic:
            st = os.path.join(COMMON, f"status_{sym}_{magic}.ini")
            t0 = time.time(); before = os.path.getmtime(st) if os.path.exists(st) else 0
            print("waiting for the EA acknowledgement ...")
            while time.time() - t0 < 1800:
                if os.path.exists(st) and os.path.getmtime(st) > before and "profile_applied" in open(st, encoding="utf-8").read():
                    print(open(st, encoding="utf-8").read()); return
                time.sleep(5)
            print("no acknowledgement within 30 min (EA reloads every InpProfileReloadBars M5 bars, live only)")
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
