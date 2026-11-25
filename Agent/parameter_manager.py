"""Parameter Manager: the last gate before any change reaches a bot.
Safe / Sensitive / Critical, step limit, cooldown. Only keys the profile gateway really accepts are listed."""
import time

# name: (class, max change per step %, cooldown hours)
CLASSES = {
    "max_trades_day": ("safe", 50, 24), "max_sl_atr": ("sensitive", 10, 48),
    # The owner explicitly delegated spread tuning to the Agent (wider step, short cooldown); the EA still clamps to its hard range.
    "max_spread_atr": ("delegated", 25, 6), "max_spread_r_pct": ("delegated", 25, 6),
}
CRITICAL = {"InpBaseRiskPct", "InpMaxRiskPct", "InpCapitalFloorDD", "InpDailyLossPct", "InpMagic"}
_last = {}


def check(bot, param, current, proposed, now=None):
    """-> (accepted, value_to_apply, reasons). Never raises; unknown or critical params are refused."""
    now = now or time.time()
    if param in CRITICAL:
        return False, current, ["critical parameter: human approval required"]
    if param not in CLASSES:
        return False, current, ["parameter is not exposed through the profile gateway"]
    _, step, cool = CLASSES[param]
    if (now - _last.get((bot, param), 0)) / 3600 < cool:
        return False, current, [f"cooldown {cool}h not over"]
    reasons, val = [], proposed
    if current and abs(proposed - current) / abs(current) * 100 > step:
        val = current * (1 + (1 if proposed > current else -1) * step / 100)
        reasons.append(f"step limited to {step}%")
    _last[(bot, param)] = now
    return True, val, reasons
