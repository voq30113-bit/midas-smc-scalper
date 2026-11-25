"""Agent loop skeleton (phase 1: OBSERVE ONLY). Reads journals, logs decisions, never writes a profile.
Run:  python agent.py
"""
import json, time
import performance_analyzer as pa
import decision_engine as de


def cycle():
    rows = pa.load()
    health = pa.health(rows)
    for symbol, h in health.items():
        d = de.decide(symbol, regime="UNKNOWN", health=h, evidence=[])   # TODO: feed a real regime from MT5 data
        print(json.dumps({"t": time.time(), "bot": symbol, "type": d.type, "reason": d.reason}))
    if not health:
        print("no journal rows yet - nothing to observe")


if __name__ == "__main__":
    cycle()
