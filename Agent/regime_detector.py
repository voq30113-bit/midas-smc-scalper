"""Regime Detector (rule-based, with hysteresis). Mirrors the Regime tab of docs/index.html."""
from dataclasses import dataclass

# adx_trend, adx_range, atr_high, atr_crisis, atr_low   (per asset group)
THRESHOLDS = {"gold": (25, 20, 1.5, 2.5, 0.8), "index": (25, 20, 1.5, 2.5, 0.8),
              "crypto": (28, 22, 1.8, 3.0, 0.7), "fx": (22, 18, 1.4, 2.2, 0.8), "oil": (25, 20, 1.6, 2.6, 0.8)}


def label(adx, atr_ratio, above_ma, group="gold"):
    ta, ra, hv, cr, lv = THRESHOLDS[group]
    if atr_ratio >= cr: return "CRISIS", min(1, .6 + (atr_ratio - cr) / cr)
    if atr_ratio >= hv: return "HIGH_VOL", min(1, .5 + (atr_ratio - hv) / (cr - hv) * .5)
    if adx >= ta: return ("TREND_UP" if above_ma else "TREND_DOWN"), min(1, .5 + (adx - ta) / 20)
    if adx < ra and atr_ratio <= lv: return "LOW_VOL_RANGE", min(1, .5 + (ra - adx) / 20)
    if adx < ra: return "RANGE", min(1, .5 + (ra - adx) / 20)
    return "TRANSITION", .4


@dataclass
class RegimeState:
    current: str = None
    cand: str = None
    count: int = 0


def step(state, adx, atr_ratio, above_ma, group="gold", confirm=3):
    """Returns (regime, confidence, changed). The regime only changes after `confirm` consecutive samples."""
    l, c = label(adx, atr_ratio, above_ma, group)
    if state.current is None:
        state.current = l
        return l, c, True
    if l == state.current:
        state.cand, state.count = None, 0
        return l, c, False
    state.count = state.count + 1 if l == state.cand else 1
    state.cand = l
    if state.count >= confirm:
        state.current, state.cand, state.count = l, None, 0
        return l, c, True
    return state.current, c, False
