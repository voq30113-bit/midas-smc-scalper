#!/usr/bin/env python3
"""
duka_fetch.py - Dukascopy XAUUSD -> MT5 custom-symbol CSV.

Downloads Dukascopy's free M1 candle data and writes a CSV that MT5 can import
as a custom symbol, so MIDAS can be backtested on a neutral feed and compared
against the broker's own history.

Binary format was verified against the live endpoint, not taken from docs:
  URL   https://datafeed.dukascopy.com/datafeed/{SYM}/{YYYY}/{MM}/{DD}/{KIND}.bi5
        ** MM is ZERO-INDEXED ** (January = 00, June = 05)
  body  raw LZMA, decompresses to 24-byte records
  rec   >IIIIIf  = time_offset_s, open, close, low, high (uint32), volume (float32)
  scale XAUUSD prices are scaled by 1000 (NOT the 100000 used for FX majors)

Usage
  python duka_fetch.py --from 2021-01-01 --to 2026-06-24
  python duka_fetch.py --from 2025-01-01 --to 2026-06-24 --digits 2 --out xau_duka.csv
  python duka_fetch.py --from 2025-01-01 --to 2025-02-01 --no-ask --fixed-spread 25

Output CSV (no header, comma separated, MT5 bar-import layout):
  2025.06.10,14:00:00,3343.36,3343.50,3340.19,3340.38,7,0,54
  date       time     open    high    low     close   tickvol,realvol,spread_points
"""

import argparse, concurrent.futures as cf, datetime as dt, lzma, os, struct, sys, time
import requests

BASE = "https://datafeed.dukascopy.com/datafeed"
UA   = {"User-Agent": "Mozilla/5.0"}
REC  = struct.Struct(">IIIIIf")          # verified against live data
SCALE_DEFAULT = 1000.0                    # XAUUSD


def day_url(symbol: str, day: dt.date, kind: str) -> str:
    # Dukascopy months are zero-indexed. This is the single most common bug in
    # home-made downloaders - it silently returns the WRONG MONTH's data.
    return f"{BASE}/{symbol}/{day.year}/{day.month - 1:02d}/{day.day:02d}/{kind}_candles_min_1.bi5"


def fetch_day(session, symbol, day, kind, cache_dir, retries=3):
    """Return {minute_offset_seconds: (o,h,l,c,v)} for one day, or {} if no data."""
    cache = os.path.join(cache_dir, f"{symbol}_{day:%Y%m%d}_{kind}.bi5")
    blob = None
    if os.path.exists(cache):
        with open(cache, "rb") as fh:
            blob = fh.read()
    else:
        url = day_url(symbol, day, kind)
        for attempt in range(retries):
            try:
                r = session.get(url, timeout=60, headers=UA)
                if r.status_code == 404:
                    blob = b""
                    break
                r.raise_for_status()
                blob = r.content
                break
            except Exception:
                if attempt == retries - 1:
                    return None                      # signal a hard failure
                time.sleep(1.5 * (attempt + 1))
        if blob is None:
            return None
        with open(cache, "wb") as fh:
            fh.write(blob)

    if not blob:
        return {}
    try:
        raw = lzma.LZMADecompressor().decompress(blob)
    except lzma.LZMAError:
        return {}

    out = {}
    for i in range(len(raw) // REC.size):
        t, o, c, l, h, v = REC.unpack_from(raw, i * REC.size)
        if o == 0:                                   # weekend / holiday / break
            continue
        out[t] = (o, h, l, c, v)
    return out


def is_padding(o, h, l, c, v):
    """Dukascopy pads the hours after the session close with the last price.

    Verified on 2025-06-13 (Friday): the 180 minutes from 21:00 UTC to midnight
    are all volume==0 AND flat OHLC, while every trading minute that day had
    non-zero volume. Feeding these to the tester would invent three hours of
    dead bars every Friday plus the daily maintenance break.
    """
    return v == 0.0 and o == h == l == c


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbol", default="XAUUSD")
    ap.add_argument("--from", dest="d_from", required=True, help="YYYY-MM-DD")
    ap.add_argument("--to", dest="d_to", required=True, help="YYYY-MM-DD (exclusive)")
    ap.add_argument("--out", default="xau_duka_m1.csv")
    ap.add_argument("--digits", type=int, default=2,
                    help="round to your BROKER's digit count so the comparison is like-for-like (gold is usually 2)")
    ap.add_argument("--scale", type=float, default=SCALE_DEFAULT)
    ap.add_argument("--no-ask", action="store_true",
                    help="skip the ASK download (halves requests) and use --fixed-spread")
    ap.add_argument("--fixed-spread", type=int, default=25,
                    help="spread in POINTS used when --no-ask is set")
    ap.add_argument("--workers", type=int, default=12)
    ap.add_argument("--cache", default=".duka_cache")
    ap.add_argument("--keep-padding", action="store_true",
                    help="keep Dukascopy's flat zero-volume post-close bars (default: drop them)")
    args = ap.parse_args()

    d0 = dt.date.fromisoformat(args.d_from)
    d1 = dt.date.fromisoformat(args.d_to)
    days = [d0 + dt.timedelta(days=i) for i in range((d1 - d0).days)]
    days = [d for d in days if d.weekday() < 5 or d.weekday() == 6]   # skip Saturdays
    os.makedirs(args.cache, exist_ok=True)

    kinds = ["BID"] if args.no_ask else ["BID", "ASK"]
    jobs = [(d, k) for d in days for k in kinds]
    print(f"{args.symbol}  {d0} -> {d1}   {len(days)} days, {len(jobs)} files, {args.workers} workers")

    results, failures = {}, []
    session = requests.Session()
    adapter = requests.adapters.HTTPAdapter(pool_connections=args.workers, pool_maxsize=args.workers)
    session.mount("https://", adapter)

    done = 0
    with cf.ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(fetch_day, session, args.symbol, d, k, args.cache): (d, k) for d, k in jobs}
        for fut in cf.as_completed(futs):
            d, k = futs[fut]
            res = fut.result()
            if res is None:
                failures.append((d, k))
            else:
                results[(d, k)] = res
            done += 1
            if done % 200 == 0 or done == len(jobs):
                print(f"  {done}/{len(jobs)} files", flush=True)

    if failures:
        print(f"\n!! {len(failures)} files failed after retries. Re-run to resume "
              f"(downloads are cached in {args.cache}/). First few: {failures[:5]}")

    point = 10.0 ** (-args.digits)
    rows, bad_ohlc, no_ask, padded = 0, 0, 0, 0
    with open(args.out, "w", newline="") as fh:
        for d in days:
            bid = results.get((d, "BID"), {})
            if not bid:
                continue
            ask = {} if args.no_ask else results.get((d, "ASK"), {})
            midnight = dt.datetime(d.year, d.month, d.day)
            for t in sorted(bid):
                o, h, l, c, v = bid[t]
                if not args.keep_padding and is_padding(o, h, l, c, v):
                    padded += 1
                    continue
                o, h, l, c = (x / args.scale for x in (o, h, l, c))
                o, h, l, c = (round(x, args.digits) for x in (o, h, l, c))
                if not (l <= min(o, c) and h >= max(o, c)):
                    bad_ohlc += 1
                    continue
                if ask:
                    a = ask.get(t)
                    if a is None:
                        spread = args.fixed_spread
                        no_ask += 1
                    else:
                        spread = int(round((a[3] / args.scale - c) / point))
                        spread = max(1, min(spread, 5000))
                else:
                    spread = args.fixed_spread
                ts = midnight + dt.timedelta(seconds=t)
                tickvol = max(1, int(round(v * 100)))
                fh.write(f"{ts:%Y.%m.%d},{ts:%H:%M:%S},{o},{h},{l},{c},{tickvol},0,{spread}\n")
                rows += 1

    print(f"\nwrote {rows:,} M1 bars -> {args.out}")
    if padded:
        print(f"  dropped {padded:,} flat zero-volume post-close bars")
    if bad_ohlc:
        print(f"  dropped {bad_ohlc} bars failing the OHLC consistency check")
    if no_ask:
        print(f"  {no_ask} bars had no matching ASK minute; used --fixed-spread")
    print("\nTimestamps are UTC. When testing on this symbol set InpServerGMT = 0.")
    print(f"Next: copy {args.out} into  <terminal data folder>\\MQL5\\Files\\  "
          f"and run the MIDAS_DukaImport script.")


if __name__ == "__main__":
    sys.exit(main())
