"""Offline screen of candidate M5 engines. Conservative fills: entry at next bar open + spread, stop checked before anything else,
trail updated only on bar close, 0.02 ATR slippage per round trip. Results in R (R = initial stop distance).
A configuration is only interesting if it is positive in BOTH halves on SEVERAL independent data sets."""
import json, os, sys, time
from collections import deque
from data import load, load_duka_gold, atr, median

HERE = os.path.dirname(os.path.abspath(__file__))
GROUPS = {"gold": ["XAUUSD", "XAUEUR", "XAUGBP", "XAGUSD"], "index": ["US30", "US500", "USTEC", "DE30", "UK100", "JP225"],
          "other": ["BTCUSD", "ETHUSD", "USOIL", "EURUSD", "GBPUSD", "USDJPY"]}


class Ctx:
    def __init__(self, bars):
        self.b = bars; n = len(bars); self.n = n
        self.A = atr(bars)
        self.day = [x[0] // 86400 for x in bars]
        self.hour = [(x[0] % 86400) // 3600 for x in bars]
        # slow ATR (about one day) for the volatility filter
        self.slow = []
        s = self.A[0]
        for a in self.A:
            s += (a - s) / 1000.0; self.slow.append(s)
        hi, lo = {}, {}
        ah, al = {}, {}
        for i, x in enumerate(bars):
            d = self.day[i]
            hi[d] = max(hi.get(d, x[2]), x[2]); lo[d] = min(lo.get(d, x[3]), x[3])
            if self.hour[i] < 7:
                ah[d] = max(ah.get(d, x[2]), x[2]); al[d] = min(al.get(d, x[3]), x[3])
        days = sorted(d for d in hi)
        self.prev = {d: (hi[p], lo[p]) for p, d in zip(days, days[1:])}
        self.asia = {d: (ah[d], al[d]) for d in ah}

    def donchian(self, N):
        hh, ll, qh, ql = [None] * self.n, [None] * self.n, deque(), deque()
        for i in range(self.n):
            if i >= N:
                while qh[0] < i - N: qh.popleft()
                while ql[0] < i - N: ql.popleft()
                hh[i], ll[i] = self.b[qh[0]][2], self.b[ql[0]][3]
            while qh and self.b[qh[-1]][2] <= self.b[i][2]: qh.pop()
            qh.append(i)
            while ql and self.b[ql[-1]][3] >= self.b[i][3]: ql.pop()
            ql.append(i)
        return hh, ll


def signals(x, kind):
    """-> list of (bar index of the signal close, +1/-1). At most one per side per day."""
    out, done = [], set()
    b = x.b
    if kind.startswith("don"):
        hh, ll = x.donchian(int(kind[3:]))
    for i in range(1100, x.n - 1):
        d, h, c = x.day[i], x.hour[i], b[i][4]
        if not 7 <= h < 20:
            continue
        side = 0
        if kind == "pdhl" and d in x.prev:
            ph, pl = x.prev[d]
            side = 1 if c > ph and b[i - 1][4] <= ph else (-1 if c < pl and b[i - 1][4] >= pl else 0)
        elif kind == "asia" and d in x.asia:
            ah, al = x.asia[d]
            side = 1 if c > ah and b[i - 1][4] <= ah else (-1 if c < al and b[i - 1][4] >= al else 0)
        elif kind.startswith("don"):
            side = 1 if c > hh[i] else (-1 if c < ll[i] else 0)
        elif kind in ("mom", "fade"):
            body = c - b[i][1]
            if abs(body) > 2.0 * x.A[i - 1]:
                side = (1 if body > 0 else -1) * (1 if kind == "mom" else -1)
        if side and (d, side) not in done:
            done.add((d, side)); out.append((i, side))
    return out


def simulate(x, sig, stop_atr, trail_atr, max_bars, tp_r=0.0, vol_min=0.0):
    """-> list of (entry_time, R). One position at a time."""
    b, A = x.b, x.A
    out, free = [], 0
    for i, side in sig:
        if i < free:
            continue
        if vol_min and A[i] < vol_min * x.slow[i]:
            continue
        a = A[i]; R = stop_atr * a; sp = b[i][5]
        if sp > 0.25 * a or R <= 0:
            continue
        j = i + 1
        e = b[j][1] + (sp if side > 0 else 0.0)          # bars are bid: longs pay the spread on entry, shorts on exit
        sl = e - side * R
        best, res = e, None
        end = min(x.n - 1, j + max_bars)
        while j <= end:
            o, h, l, c = b[j][1], b[j][2], b[j][3], b[j][4]
            ask = 0.0 if side > 0 else sp
            if (side > 0 and l <= sl) or (side < 0 and h + ask >= sl):
                px = min(o, sl) if side > 0 else max(o + ask, sl)
                res = side * (px - e); break
            if tp_r and ((side > 0 and h >= e + tp_r * R) or (side < 0 and l + ask <= e - tp_r * R)):
                res = tp_r * R; break
            if x.day[j] != x.day[i] or (x.hour[j] >= 21):                 # flat before the day roll
                res = side * (c + ask - e); break
            best = max(best, c) if side > 0 else min(best, c)
            if trail_atr:
                t = best - side * trail_atr * a
                sl = max(sl, t) if side > 0 else min(sl, t)
            j += 1
        if res is None:
            j = end; res = side * (b[end][4] + (0.0 if side > 0 else sp) - e)
        out.append((b[i][0], (res - 0.02 * a) / R))
        free = j + 1
    return out


def stats(tr, split):
    r = [v for _, v in tr]
    a = [v for t, v in tr if t < split]; c = [v for t, v in tr if t >= split]
    gl = -sum(v for v in r if v < 0)
    return {"n": len(r), "exp": sum(r) / len(r) if r else 0, "pf": sum(v for v in r if v > 0) / gl if gl else 0,
            "e1": sum(a) / len(a) if a else 0, "e2": sum(c) / len(c) if c else 0}


def configs():
    for kind in ("pdhl", "asia", "don96", "don288", "mom", "fade"):
        for stop in (3, 6, 10):
            for trail, hold, tp in ((0, 24, 0), (0, 288, 0), (stop, 288, 0), (2 * stop, 288, 0), (0, 72, 1.5)):
                for vol in (0.0, 1.0):
                    yield (kind, stop, trail, hold, tp, vol)


def main(symbols):
    out_path = os.path.join(HERE, "engines_results.json")
    res = json.load(open(out_path)) if os.path.exists(out_path) else {}
    for s in symbols:
        bars = load_duka_gold() if s == "XAUUSD_DUKA" else load(s)
        x = Ctx(bars)
        split = 1704067200 if s == "XAUUSD_DUKA" else bars[len(bars) // 2][0]          # Duka: 2021-23 vs 2024-26
        sigs = {}
        res[s] = {}
        t0 = time.time()
        for cfg in configs():
            kind, stop, trail, hold, tp, vol = cfg
            if kind not in sigs:
                sigs[kind] = signals(x, kind)
            res[s]["|".join(map(str, cfg))] = stats(simulate(x, sigs[kind], stop, trail, hold, tp, vol), split)
        print(s, "done", round(time.time() - t0), "s", flush=True)
        json.dump(res, open(out_path, "w"))


if __name__ == "__main__":
    main(sys.argv[1:] or sum(GROUPS.values(), []) + ["XAUUSD_DUKA"])
