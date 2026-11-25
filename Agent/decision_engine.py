"""Decision Engine skeleton. Default answer is HOLD; every decision carries a reason."""
from dataclasses import dataclass, field

TYPES = ("hold", "switch_profile", "tune", "derisk", "pause", "alert")


@dataclass
class Decision:
    bot: str
    type: str = "hold"
    reason: str = "no evidence for a change"
    param: str = None
    current: float = None
    proposed: float = None
    notes: list = field(default_factory=list)


def decide(bot, regime, health, evidence):
    """regime: label; health: one entry of performance_analyzer.health(); evidence: experience_store.query().
    TODO (phase 3): real logic. Today only safe rules: not enough data -> hold, degradation -> alert."""
    if health.get("status") == "review":
        return Decision(bot, "alert", "expectancy fell from %.2fR to %.2fR in regime %s"
                        % (health["before_r"], health["recent_r"], regime))
    return Decision(bot)
