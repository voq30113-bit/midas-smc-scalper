"""Characteristics per asset: volatility, cost, trend/mean-reversion tendency, behaviour around price levels.
All forward returns are in ATR units (positive = continuation in the direction of the event) and shown as first half / second half,
because an effect that flips sign between halves is noise."""
import math, sys, time
from data import load, load_duka_gold, atr, median

SYMS = ["XAUUSD", "XAUEUR", "XAUGBP", "XAGUSD", "US30", "US500", "USTEC", "DE30", "UK100", "JP225", "BTCUSD", "ETHUSD", "USOIL", "EURUSD", "GBPUSD", "USDJPY"]
ROUND = {"XAUUSD": 10, "XAUUSD_DUKA": 10, "XAUEUR": 10, "XAUGBP": 10, "XAGUSD": 0.5, "US30": 100, "US500": 25, "USTEC": 100, "DE30": 100,
         "UK100": 50, "JP225": 500, "BTCUSD": 1000, "ETHUSD": 50, "USOIL": 1, "EURUSD": 0.005, "GBPUSD": 0.005, "USDJPY": 0.5}


def vr(c, q):
    r = [math.log(c[i] / c[i - 1]) for i in range(1, len(c))]
    m = sum(r) / len(r); v1 = sum((x - m) ** 2 for x in r) / len(r)
    rq = [math.log(c[i] / c[i - q]) for i in range(q, len(c))]
    vq = sum((x - q * m) ** 2 for x in rq) / len(rq)
    return vq / (q * v1)


def halves(ev):
    """ev: list of (index, value) -> 'n mean1 mean2' split by time."""
    if len(ev) < 20:
        return f"n={len(ev):4d}   few"
    ev.sort(); k = len(ev) // 2
    a = sum(v for _, v in ev[:k]) / k; b = sum(v for _, v in ev[k:]) / (len(ev) - k)
    return f"n={len(ev):4d} {a:+.2f} {b:+.2f}"


def profile(name, bars):
    A = atr(bars); c = [b[4] for b in bars]; n = len(bars)
    atr_bp = median([A[i] / c[i] * 1e4 for i in range(n)])
    sp = median([bars[i][5] / A[i] for i in range(100, n) if A[i] > 0])
    hr = [[0.0, 0] for _ in range(24)]
    for i in range(100, n):
        h = time.gmtime(bars[i][0]).tm_hour
        hr[h][0] += (bars[i][2] - bars[i][3]) / A[i]; hr[h][1] += 1
    top = sorted(range(24), key=lambda h: -(hr[h][0] / max(1, hr[h][1])))[:4]
    print(f"\n=== {name}  {time.strftime('%Y-%m-%d', time.gmtime(bars[0][0]))}..{time.strftime('%Y-%m-%d', time.gmtime(bars[-1][0]))}")
    print(f"ATR M5 {atr_bp:.1f} bp | spread/ATR {sp:.3f} | busiest hours UTC {sorted(top)} | VR(30m) {vr(c,6):.2f} VR(1h) {vr(c,12):.2f} VR(4h) {vr(c,48):.2f}")
    # day structure
    days = {}
    for i, b in enumerate(bars):
        days.setdefault(b[0] // 86400, []).append(i)
    keys = [d for d in sorted(days) if len(days[d]) > 150]
    H = 24  # 2h forward
    pd_ev, as_ev, rn_ev, big_ev, ext_ev, or_ev = [], [], [], [], [], []
    for k in range(1, len(keys)):
        prev, cur = days[keys[k - 1]], days[keys[k]]
        ph = max(bars[i][2] for i in prev); pl = min(bars[i][3] for i in prev)
        asia = [i for i in cur if time.gmtime(bars[i][0]).tm_hour < 7]
        ah = max((bars[i][2] for i in asia), default=None); al = min((bars[i][3] for i in asia), default=None)
        done = set()
        for i in cur:
            if i + H >= n or A[i] <= 0:
                continue
            h = time.gmtime(bars[i][0]).tm_hour
            fwd = (c[i + H] - c[i]) / A[i]
            if "pu" not in done and c[i] > ph:
                pd_ev.append((i, fwd)); done.add("pu")
            if "pd" not in done and c[i] < pl:
                pd_ev.append((i, -fwd)); done.add("pd")
            if ah is not None and 7 <= h < 17:
                if "au" not in done and c[i] > ah:
                    as_ev.append((i, fwd)); done.add("au")
                if "ad" not in done and c[i] < al:
                    as_ev.append((i, -fwd)); done.add("ad")
    last = -99
    R = ROUND.get(name, 0)
    for i in range(100, n - H):
        fwd = (c[i + H] - c[i]) / A[i]
        if R and math.floor(c[i] / R) != math.floor(c[i - 1] / R) and i - last > 12:
            rn_ev.append((i, fwd if c[i] > c[i - 1] else -fwd)); last = i
        body = c[i] - bars[i][1]
        if abs(body) > 2.0 * A[i - 1]:
            big_ev.append((i, math.copysign(1, body) * (c[i + 12] - c[i]) / A[i]))
        m = sum(c[i - 47:i + 1]) / 48
        z = (c[i] - m) / (A[i] * 4)
        if abs(z) > 1.0 and abs((c[i - 1] - m) / (A[i] * 4)) <= 1.0:
            ext_ev.append((i, math.copysign(1, z) * fwd))
    print(f"  forward 2h after first close beyond previous-day high/low : {halves(pd_ev)}")
    print(f"  forward 2h after London/NY break of Asia range            : {halves(as_ev)}")
    print(f"  forward 2h after crossing a round number ({R})             : {halves(rn_ev)}")
    print(f"  forward 1h after a >2 ATR body bar                        : {halves(big_ev)}")
    print(f"  forward 2h after stretching 4 ATR from 4h mean            : {halves(ext_ev)}")
    # session drift by hour block (in ATR units per block)
    blk = {}
    for k in keys:
        ix = days[k]
        for lo, hi in ((0, 7), (7, 13), (13, 17), (17, 21), (21, 24)):
            s = [i for i in ix if lo <= time.gmtime(bars[i][0]).tm_hour < hi]
            if len(s) > 10:
                blk.setdefault((lo, hi), []).append((s[0], (c[s[-1]] - bars[s[0]][1]) / A[s[0]]))
    print("  drift per UTC block (ATR, halves): " + " | ".join(f"{lo:02d}-{hi:02d} {halves(v)[7:]}" for (lo, hi), v in blk.items()))


if __name__ == "__main__":
    for s in (sys.argv[1:] or SYMS):
        profile(s, load(s))
    if len(sys.argv) < 2:
        profile("XAUUSD_DUKA", load_duka_gold())
