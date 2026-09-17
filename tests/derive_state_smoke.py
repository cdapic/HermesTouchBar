#!/usr/bin/env python3
"""Smoke tests for hermes_source._derive_state (Tier A.3) + mid-turn
detection (hotfix #2: plain-text replies stream without writing state.db
rows, so the message tail alone reads "ready" mid-generation).

Same print-and-exit style as the Swift smokes in tests/*.swift: every
assertion prints, failures accumulate an exit code.
"""
import importlib.util
import os
import sys
import tempfile
import time
from pathlib import Path

# Isolate HERMES_HOME so _read_agent_turn can be exercised against a
# synthetic agent.log. Import AFTER setting the env var (the module reads it
# at import time).
TMP = tempfile.mkdtemp(prefix="hermes-tb-test-")
os.environ["HERMES_HOME"] = TMP

SRC = (
    Path(__file__).resolve().parent.parent
    / "HermesTouchBar/Data/hermes_source.py"
)
spec = importlib.util.spec_from_file_location("hermes_source", SRC)
hs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hs)

failed = 0
total = 0


def check(name: str, got, want):
    global failed, total
    total += 1
    ok = got == want
    if not ok:
        failed += 1
    print(f"  {'OK ' if ok else 'FAIL'} {name}: got={got!r} want={want!r}")


NOW = 1_789_552_000.0  # fixed "now" for deterministic windows


def msg(role: str, ts: float, **kw):
    m = {"role": role, "timestamp": ts}
    m.update(kw)
    return m


def derive(msgs, last_activity=None, in_turn=False, has_session=True):
    return hs._derive_state(
        msgs, last_activity, NOW, has_session, in_turn=in_turn
    )


print("== _derive_state — Tier A.3 baseline (13 scenarios) ==")

# 1. assistant + error finish → error (30s window)
check("assistant error → error", derive([msg("assistant", NOW - 5, finish_reason="error")]), "error")
# 2. assistant + error, aged past window → ready
check("assistant error 40s → ready", derive([msg("assistant", NOW - 40, finish_reason="error")]), "ready")
# 3. assistant + tool_calls → working
check("assistant tool_calls → working", derive([msg("assistant", NOW - 5, finish_reason="tool_calls")]), "working")
# 4. assistant + tool_calls, aged past window, heartbeat fresh → working (sticky)
check(
    "assistant tool_calls 70s + fresh heartbeat → working (sticky)",
    derive([msg("assistant", NOW - 70, finish_reason="tool_calls")], last_activity=NOW - 30),
    "working",
)
# 5. assistant + tool_calls, aged past window, heartbeat dead → ready
check(
    "assistant tool_calls 70s + dead heartbeat → ready",
    derive([msg("assistant", NOW - 70, finish_reason="tool_calls")], last_activity=NOW - 200),
    "ready",
)
# 6. assistant + stop → ok (12s)
check("assistant stop → ok", derive([msg("assistant", NOW - 5, finish_reason="stop")]), "ok")
# 7. assistant + stop, aged past window → ready
check("assistant stop 15s → ready", derive([msg("assistant", NOW - 15, finish_reason="stop")]), "ready")
# 8. assistant + reasoning → thinking (sticky)
check(
    "assistant reasoning → thinking",
    derive([msg("assistant", NOW - 5, reasoning_content="…", finish_reason=None)]),
    "thinking",
)
# 9. assistant + NULL finish → streaming (sticky)
check("assistant null finish → streaming", derive([msg("assistant", NOW - 5)]), "streaming")
# 10. tool last → working (sticky)
check("tool last → working", derive([msg("tool", NOW - 5)]), "working")
# 11. user last → ready
check("user last → ready", derive([msg("user", NOW - 5)]), "ready")
# 12. empty messages + has session → ready
check("empty + session → ready", derive([], has_session=True), "ready")
# 13. empty messages + no session → idle
check("empty + no session → idle", derive([], has_session=False), "idle")

print("== _derive_state — hotfix #2 mid-turn (in_turn) ==")

# 14. user last + mid-turn → working (Hermes accepted the prompt)
check("user last + in_turn → working", derive([msg("user", NOW - 5)], in_turn=True), "working")
# 15. user last + mid-turn, aged past 60s, heartbeat fresh → working (sticky)
check(
    "user last + in_turn 70s + fresh heartbeat → working (sticky)",
    derive([msg("user", NOW - 70)], last_activity=NOW - 30, in_turn=True),
    "working",
)
# 16. user last + mid-turn, aged past 60s, heartbeat dead → ready
check(
    "user last + in_turn 70s + dead heartbeat → ready",
    derive([msg("user", NOW - 70)], last_activity=NOW - 200, in_turn=True),
    "ready",
)
# 17. user last + NOT mid-turn → ready (regression guard)
check("user last + no in_turn → ready", derive([msg("user", NOW - 5)], in_turn=False), "ready")

print("== _read_agent_turns — synthetic agent.log (per-session) ==")

LOG = Path(TMP) / "logs" / "agent.log"
LOG.parent.mkdir(parents=True, exist_ok=True)
T = time.strptime("2026-09-16 17:41:21", "%Y-%m-%d %H:%M:%S")
START_TS = time.mktime(T) + 0.595
END_TS = time.mktime(time.strptime("2026-09-16 17:41:39", "%Y-%m-%d %H:%M:%S")) + 0.637
SID_A = "20260916_172227_03a9ac"
SID_B = "20260916_171500_deadbeef"


def stamp(ts: float) -> str:
    lt = time.localtime(ts)
    ms = int(round((ts - int(ts)) * 1000))
    return time.strftime("%Y-%m-%d %H:%M:%S", lt) + f",{ms:03d}"


# a) no log → {}
if LOG.exists():
    LOG.unlink()
check("missing log → {}", hs._read_agent_turns(), {})

# b) turn start only (bracket sid) → {sid: (ts, None)}
LOG.write_text(
    stamp(START_TS)
    + f" INFO [{SID_A}] agent.turn_context: conversation turn: session=… msg='hi'\n",
    encoding="utf-8",
)
turns = hs._read_agent_turns()
s, e = turns.get(SID_A, (None, None))
check("start only (bracket sid) → (ts, None)",
      (SID_A in turns, s is not None and abs(s - START_TS) < 0.01, e),
      (True, True, None))

# c) start then end → both set, end later
LOG.write_text(
    stamp(START_TS)
    + f" INFO [{SID_A}] agent.turn_context: conversation turn: …\n"
    + stamp(END_TS)
    + f" INFO [{SID_A}] agent.conversation_loop: Turn ended: reason=text_response(finish_reason=stop) …\n",
    encoding="utf-8",
)
turns = hs._read_agent_turns()
s, e = turns.get(SID_A, (None, None))
check("start+end → both set, end later",
      (SID_A in turns, abs(s - START_TS) < 0.01, abs(e - END_TS) < 0.01, e > s),
      (True, True, True, True))

# d) tui prompt accepted uses agent_session_id= keyword; garbage ignored
LOG.write_text(
    "not a log line\n\n"
    + stamp(START_TS)
    + f" INFO tui_gateway.server: tui prompt accepted: ui_session=ab944edf session_key=202609...a9ac agent_session_id={SID_A} kind=user chars=27\n",
    encoding="utf-8",
)
turns = hs._read_agent_turns()
s, e = turns.get(SID_A, (None, None))
check("garbage ignored, prompt accepted (keyword sid) counts as start",
      (SID_A in turns, s is not None and abs(s - START_TS) < 0.01, e),
      (True, True, None))

# e) two sessions stay independent — A mid-turn, B finished
LOG.write_text(
    stamp(START_TS)
    + f" INFO [{SID_A}] agent.turn_context: conversation turn: …\n"
    + stamp(START_TS + 5)
    + f" INFO [{SID_B}] agent.turn_context: conversation turn: …\n"
    + stamp(START_TS + 7)
    + f" INFO [{SID_B}] agent.conversation_loop: Turn ended: …\n",
    encoding="utf-8",
)
turns = hs._read_agent_turns()
sa, ea = turns.get(SID_A, (None, None))
sb, eb = turns.get(SID_B, (None, None))
check("two sessions independent (A mid-turn, B done)",
      (sa is not None and ea is None, sb is not None and eb is not None),
      (True, True))

# f) turn event with NO resolvable session id is skipped
LOG.write_text(
    stamp(START_TS)
    + " INFO agent.conversation_loop: Turn ended: … (no sid anywhere)\n",
    encoding="utf-8",
)
check("sid-less turn events skipped", hs._read_agent_turns(), {})

print(f"\n== {total - failed}/{total} passed, {failed} failed ==")
sys.exit(1 if failed else 0)
