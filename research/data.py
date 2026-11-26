"""Bar loading for offline research (pure Python). Bars: [time, open, high, low, close, spread_price]; time = epoch UTC."""
import calendar, os

BARS = os.path.join(os.environ.get("APPDATA", ""), "MetaQuotes", "Terminal", "Common", "Files", "MIDAS", "bars")
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def load(symbol):
    """Exness M5 bars exported by tools/MIDAS_ExportBars.mq5."""
    out = []
    with open(os.path.join(BARS, symbol + ".csv")) as f:
        point = float(f.readline().split(",")[1])
        for ln in f:
            t, o, h, l, c, s = ln.split(",")
            out.append([int(t), float(o), float(h), float(l), float(c), int(s) * point])
    return out


def load_duka_gold(point=0.001):
    """Dukascopy XAUUSD M1 (2021-) resampled to M5; spread column of that file is in points of a 3-digit gold quote /10."""
    out, cur = [], None
    days = {}
    with open(os.path.join(ROOT, "tools", "xau_duka_m1.csv")) as f:
        for ln in f:
            d, tm, o, h, l, c, _, _, s = ln.split(",")
            base = days.get(d)
            if base is None:
                base = days[d] = calendar.timegm((int(d[:4]), int(d[5:7]), int(d[8:10]), 0, 0, 0))
            t = base + int(tm[:2]) * 3600 + int(tm[3:5]) // 5 * 300
            o, h, l, c = float(o), float(h), float(l), float(c)
            if cur is None or cur[0] != t:
                cur = [t, o, h, l, c, int(s) * 0.01]
                out.append(cur)
            else:
                cur[2] = max(cur[2], h); cur[3] = min(cur[3], l); cur[4] = c
    return out


def atr(bars, n=14):
    out, a, pc = [], None, bars[0][4]
    for b in bars:
        tr = max(b[2] - b[3], abs(b[2] - pc), abs(b[3] - pc)); pc = b[4]
        a = tr if a is None else a + (tr - a) / n
        out.append(a)
    return out


def median(x):
    x = sorted(x); n = len(x)
    return 0.0 if not n else (x[n // 2] if n % 2 else (x[n // 2 - 1] + x[n // 2]) / 2)
