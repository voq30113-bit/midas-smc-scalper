"""Neighbourhood and stress test of the momentum-bar engine: body > K*ATR, stop S*ATR, hold to end of day, volatility filter V."""
import math, sys
from data import load
from engines import Ctx, simulate

SYMS = sys.argv[1:] or ["US30", "US500", "USTEC", "DE30"]


def sig(x, K, hours):
    out, done = [], set()
    for i in range(1100, x.n - 1):
        if not hours[0] <= x.hour[i] < hours[1]:
            continue
        body = x.b[i][4] - x.b[i][1]
        if abs(body) > K * x.A[i - 1]:
            side = 1 if body > 0 else -1
            if (x.day[i], side) not in done:
                done.add((x.day[i], side)); out.append((i, side))
    return out


def run(ctx, K=2.0, S=3, V=1.0, hours=(7, 20), tp=0.0, hold=288, slip=1.0):
    all_ = []
    for s, x in ctx.items():
        if slip != 1.0:
            for b in x.b: b[5] *= slip
        tr = simulate(x, sig(x, K, hours), S, 0, hold, tp, V)
        if slip != 1.0:
            for b in x.b: b[5] /= slip
        all_ += [(t, r, s) for t, r in tr]
    all_.sort()
    r = [v for _, v, _ in all_]; n = len(r); m = sum(r) / n
    sd = math.sqrt(sum((v - m) ** 2 for v in r) / (n - 1))
    h = n // 2
    per = " ".join(f"{s}:{sum(v for _, v, y in all_ if y == s)/max(1,sum(y == s for _, _, y in all_)):+.2f}" for s in ctx)
    cum = pk = dd = 0
    for v in r:
        cum += v; pk = max(pk, cum); dd = max(dd, pk - cum)
    pf = sum(v for v in r if v > 0) / -sum(v for v in r if v < 0)
    months = {}
    for t, v, _ in all_:
        months[t // 2629800] = months.get(t // 2629800, 0) + v
    return (f"n={n:5d} exp={m:+.3f} t={m/sd*math.sqrt(n):4.1f} PF={pf:.2f} half {sum(r[:h])/h:+.2f}/{sum(r[h:])/(n-h):+.2f} maxDD={dd:5.1f}R "
            f"months+ {sum(v > 0 for v in months.values())}/{len(months)} | {per}")


if __name__ == "__main__":
    ctx = {s: Ctx(load(s)) for s in SYMS}
    print("base          ", run(ctx))
    for K in (1.5, 2.5, 3.0): print(f"K={K}         ", run(ctx, K=K))
    for S in (2, 4, 5): print(f"S={S}           ", run(ctx, S=S))
    for V in (0.0, 0.8, 1.2, 1.5): print(f"V={V}         ", run(ctx, V=V))
    for h in ((7, 13), (13, 17), (13, 20), (0, 20)): print(f"hours={h}  ", run(ctx, hours=h))
    for hold in (24, 48, 96): print(f"hold={hold}      ", run(ctx, hold=hold))
    for tp in (2.0, 4.0): print(f"tp={tp}R       ", run(ctx, tp=tp))
    print("spread x2     ", run(ctx, slip=2.0))
