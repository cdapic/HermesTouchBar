#!/usr/bin/env python3
"""Long-running Hermes state emitter for HermesTouchBar (Tier A.2).

Spawned by `HermesTouchBar.app/Contents/MacOS/HermesTouchBar` via the
`HermesPythonSource` Swift actor. Emits one JSON object per line to stdout
at a configurable cadence (default 0.5s). The Swift side parses these as
`HermesStatus` v1 schema and repaints the Touch Bar.

Stdout contract (line-delimited JSON; one object per line):

    {
      "v": 1,
      "ts": 1789440715.535,
      "gateway": {"running": true, "manager": "launchd", "pids": [5965, 5730]},
      "session": {
        "id": "...", "source": "...", "model": "...",
        "started_at": ..., "last_active": ...
      } | null,
      "state": "working",  # Tier A.3 — Hermes-authoritative state derived from
                           # the session tail + live heartbeat (idle/ready/
                           # thinking/working/streaming/ok/error); null when
                           # Hermes is unreachable (Swift falls back to its
                           # own time-window heuristics)
      "approval": {
        "pending": false, "prompt": null, "tool": null
      },
      "cron": {
        "last_fired_at": null, "recent_job_id": null
      },
      "skin": "slate",      # current display.skin from config.yaml
      "recent_messages": [  # last 5 messages of active session
        {
          "role": "assistant",
          "timestamp": 1783647576.45,
          "tool_name": null,
          "finish_reason": "tool_calls",
          "is_reasoning": false
        },
        ...
      ]
    }

Why Python introspection instead of CLI flags:
- Hermes CLI doesn't expose `--json --watch` and won't anytime soon. Spawning
  our own subprocess that imports `hermes_cli.*` modules is faster, more
  reliable, and doesn't depend on upstream.
- `get_gateway_runtime_snapshot()` and `SessionDB.get_messages()` are the
  same calls `hermes status` and the TUI use, so we agree with them.

ENV:
    HERMES_HOME                  # default ~/.hermes
    HERMES_TOUCHBAR_INTERVAL     # seconds between emits; default 0.5

Errors:
- Any exception inside the loop is caught and the field is set to a safe
  default. We never kill the process; stale frames are better than silence.
- A top-level import failure (Hermes missing entirely) emits one synthetic
  frame with `_error` set, then exits.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any, Iterable

HERMES_HOME = Path(os.environ.get("HERMES_HOME", "~/.hermes")).expanduser()
HERMES_AGENT = HERMES_HOME / "hermes-agent"
if str(HERMES_AGENT) not in sys.path:
    sys.path.insert(0, str(HERMES_AGENT))

INTERVAL_S = float(os.environ.get("HERMES_TOUCHBAR_INTERVAL", "0.5"))

# Late import so a Hermes install failure is reported cleanly.
try:
    from hermes_cli.gateway import get_gateway_runtime_snapshot  # type: ignore
    from hermes_state import SessionDB  # type: ignore
    _IMPORT_ERROR: str | None = None
except Exception as e:
    _IMPORT_ERROR = f"hermes modules unavailable: {e}"


# ---------------------------------------------------------------------------
# Helpers that don't need the heavy Hermes modules
# ---------------------------------------------------------------------------

def _read_current_skin() -> str | None:
    """Parse ~/.hermes/config.yaml for `display.skin: <name>`.

    Hand-rolled line scan to avoid pulling in PyYAML. Tolerates leading
    whitespace and comments. Returns None if not set.
    """
    cfg = HERMES_HOME / "config.yaml"
    if not cfg.exists():
        return None
    try:
        for raw in cfg.read_text(encoding="utf-8").splitlines():
            line = raw.split("#", 1)[0].rstrip()
            stripped = line.lstrip()
            # Match `display.skin: name` or indented `skin: name` under a
            # `display:` block (we accept the simpler `display.skin: name`
            # form first; fall through to block scan).
            m = re.match(r"^display\.skin:\s*([^\s#]+)\s*$", stripped)
            if m:
                return m.group(1)
            # Indented `skin:` inside a `display:` block — record start.
        # Block-scan fallback: find the `display:` line, then look at the
        # next 10 lines for an indented `skin: name`.
        lines = cfg.read_text(encoding="utf-8").splitlines()
        for i, raw in enumerate(lines):
            if raw.split("#", 1)[0].rstrip() == "display:":
                for j in range(i + 1, min(i + 11, len(lines))):
                    inner = lines[j].split("#", 1)[0].rstrip()
                    m = re.match(r"^\s+skin:\s*([^\s#]+)\s*$", inner)
                    if m:
                        return m.group(1)
                break
    except Exception:
        pass
    return None


def _read_cron_last_fired() -> tuple[float | None, str | None]:
    """Read ~/.hermes/cron/jobs.json for the most recent `last_run_at`
    across all enabled jobs. Falls back to file mtime if no per-job field.

    Returns (epoch_seconds, recent_job_id) or (None, None).
    """
    jobs_file = HERMES_HOME / "cron" / "jobs.json"
    if not jobs_file.exists():
        return (None, None)
    try:
        with open(jobs_file, encoding="utf-8-sig") as f:
            data = json.load(f)
        jobs = data.get("jobs", []) if isinstance(data, dict) else []
        last_ts: float | None = None
        last_id: str | None = None
        for j in jobs:
            ts = j.get("last_run_at")
            if isinstance(ts, (int, float)) and (last_ts is None or ts > last_ts):
                last_ts = float(ts)
                last_id = j.get("id") or j.get("name")
        # Fallback to mtime if no per-job timestamps.
        if last_ts is None:
            last_ts = jobs_file.stat().st_mtime
        return (last_ts, last_id)
    except Exception:
        return (None, None)


# Finish-reason values that mark the turn as ended in a provider or agent
# error (mirrors _ERROR_FINISH_REASONS in hermes_state.py).
_ERROR_FINISH_REASONS = frozenset({"error", "agent_error", "content_filter"})


def _derive_state(
    messages: list[dict[str, Any]],
    last_activity_at: float | None,
    now: float,
    has_active_session: bool,
) -> str | None:
    """Derive the authoritative Hermes state from the active session's tail
    (Tier A.3).

    Mirrors Hermes' own classify_session_status semantics (hermes_state.py:
    the LAST message's shape decides the lifecycle) plus DESIGN §2
    thresholds:

      assistant + error finish_reason  → error   (30s window)
      assistant + tool_calls / finish  → working (5s)
      assistant + finish=stop          → ok      (12s)
      assistant + reasoning            → thinking(5s)
      assistant + NULL finish_reason   → streaming (8s) — the model is still
                                         emitting; Hermes writes assistant rows
                                         in real time (69 NULL-finish rows in
                                         state.db), so a NULL finish on the
                                         last row means output is in flight.
      tool as the last row             → working (5s) — result just landed,
                                         agent is consuming it.
      user as the last row             → ready — waiting for input.

    The age used for window decay comes from the session's live
    last_activity_at heartbeat (Hermes refreshes it while the agent is
    active), NOT the last message's timestamp, so a long-running response
    doesn't wrongly decay to ready. Returns None only when the caller has
    no session-level evidence (empty list, no activity).
    """
    if not messages:
        return "ready" if has_active_session else "idle"
    last = messages[-1]
    role = (last.get("role") or "").strip().lower()
    finish = ((last.get("finish_reason") or "").strip().lower() or None)
    has_tool = bool(last.get("tool_calls"))
    has_reasoning = bool(last.get("reasoning") or last.get("reasoning_content"))
    age = (now - float(last_activity_at)) if isinstance(last_activity_at, (int, float)) else None

    def decay(window: float, state: str) -> str:
        if age is None or age < window:
            return state
        return "ready" if has_active_session else "idle"

    if role == "assistant":
        if finish in _ERROR_FINISH_REASONS:
            return decay(30.0, "error")
        if finish == "tool_calls" or has_tool:
            return decay(5.0, "working")
        if finish == "stop":
            return decay(12.0, "ok")
        if has_reasoning:
            return decay(5.0, "thinking")
        return decay(8.0, "streaming")
    if role == "tool":
        return decay(5.0, "working")
    if role == "user":
        return "ready"
    return "ready" if has_active_session else "idle"


def _read_pending_approval() -> dict[str, Any]:
    """Detect a pending approval from ~/.hermes/approvals/*.json.

    Hermes itself keeps approvals in memory only (approval_transport.py —
    nothing is persisted), so the desktop_attention plugin writes one JSON
    file per approval request here and removes it when the user answers:

        {
          "command": "rm -rf /tmp/x",
          "description": "...",
          "session_key": "...",
          "surface": "tui",
          "created_at": 1789525000.0,
          "timeout_seconds": 300.0
        }

    A file is "pending" while `created_at + timeout_seconds` is still in
    the future (the old heuristic only looked at a 30s mtime window, which
    missed approvals whose timeout is longer). Expired files are swept.

    Returns the standard `{pending, prompt, tool}` shape with `pending=False`
    when nothing looks pending.
    """
    approvals_dir = HERMES_HOME / "approvals"
    if not approvals_dir.is_dir():
        return {"pending": False, "prompt": None, "tool": None}
    now = time.time()
    best: dict[str, Any] | None = None
    try:
        for entry in approvals_dir.iterdir():
            if entry.suffix != ".json":
                continue
            try:
                data = json.loads(entry.read_text(encoding="utf-8"))
                created = float(data.get("created_at") or entry.stat().st_mtime)
                timeout = float(data.get("timeout_seconds") or 300)
                if now - created > timeout:
                    try:
                        entry.unlink()  # stale — sweep
                    except Exception:
                        pass
                    continue
                cmd = str(data.get("command") or "").strip()
                desc = str(data.get("description") or "").strip()
                prompt = f"{cmd}\n{desc}".strip()[:200] or None
                # Newest pending request wins.
                if best is None or created > best["_created"]:
                    best = {
                        "pending": True,
                        "prompt": prompt,
                        "tool": str(data.get("tool") or entry.stem or None),
                        "_created": created,
                    }
            except Exception:
                continue
    except Exception:
        pass
    if best:
        best.pop("_created", None)
        return best
    return {"pending": False, "prompt": None, "tool": None}


# ---------------------------------------------------------------------------
# Heavy Hermes-dependent collector
# ---------------------------------------------------------------------------

def _collect() -> dict[str, Any]:
    gateway_info: dict[str, Any] = {"running": False, "manager": "unknown", "pids": []}
    session_info: dict[str, Any] | None = None
    recent_messages: list[dict[str, Any]] = []
    error: str | None = _IMPORT_ERROR

    if _IMPORT_ERROR is None:
        # Gateway
        try:
            gw = get_gateway_runtime_snapshot()
            gateway_info = {
                "running": bool(gw.running),
                "manager": str(gw.manager),
                "pids": list(gw.gateway_pids),
            }
        except Exception as e:
            error = (error + "; " if error else "") + f"gateway snapshot failed: {e}"

        # Sessions + recent messages. Emit BOTH:
        #   - `session` (legacy): the most-recently-active single session, for
        #     backwards compatibility with the existing wire consumers.
        #   - `sessions` (new in Tier B): ALL active sessions sorted by
        #     last_active desc, so the Touch Bar can show a count and let
        #     the user pick one to pin. Plus `session_count` for the
        #     header chrome.
        all_sessions: list[dict[str, Any]] = []
        # Pre-initialize so a session-listing exception can't leave these
        # undefined and NameError the frame (the loop would then emit
        # nothing instead of a degraded frame).
        context_tokens: int | None = None
        context_max: int | None = None
        derived_state: str | None = None
        try:
            db = SessionDB()
            try:
                # Two disjoint sources, merged into one picker list:
                #   1. Gateway sessions (session_key NOT NULL) — weixin/feishu
                #      platform conversations, via list_gateway_sessions.
                #   2. Active non-gateway sessions (session_key IS NULL) —
                #      TUI/CLI/desktop sessions, which never carry a gateway
                #      routing key and are therefore invisible to
                #      list_gateway_sessions (its WHERE session_key IS NOT NULL
                #      drops them entirely). list_sessions_rich has no
                #      active_only flag, so we filter `ended_at IS NULL` and
                #      source in {tui, cli, desktop} client-side.
                raw_sessions = db.list_gateway_sessions(active_only=True) or []
                try:
                    rich = db.list_sessions_rich(
                        sources=["tui", "cli", "desktop"],
                        order_by_last_active=True,
                        limit=50,
                        compact_rows=True,
                    ) or []
                    raw_sessions.extend(
                        s for s in rich
                        if s.get("ended_at") is None and s.get("id")
                    )
                except Exception as e:
                    error = (error + "; " if error else "") + f"rich session listing failed: {e}"

                # De-duplicate by id, then sort newest-first; emit every
                # session as a summary.
                seen: set[str] = set()
                merged: list[dict[str, Any]] = []
                for s in raw_sessions:
                    sid = s.get("session_id") or s.get("id")
                    if not sid or sid in seen:
                        continue
                    seen.add(sid)
                    merged.append({
                        "id": sid,
                        "source": s.get("source"),
                        "model": s.get("model"),
                        "started_at": s.get("started_at"),
                        "last_active": s.get("last_active"),
                        # Live heartbeat — refreshed while the agent is
                        # active. Drives the state-window decay in
                        # _derive_state so a long response doesn't drop to
                        # ready mid-stream.
                        "last_activity_at": s.get("last_activity_at") or s.get("last_active"),
                        # TUI/CLI sessions carry a human-readable title
                        # (e.g. "评审Matrix看板widget方案"); gateway sessions
                        # may not. Swift falls back to source+id when empty.
                        "title": s.get("title"),
                        # provider matters for get_model_context_length():
                        # without it, deepseek-flash resolves to the 128k
                        # models.dev fallback instead of the real 1M window.
                        "billing_provider": s.get("billing_provider"),
                    })
                merged.sort(
                    key=lambda s: s.get("last_active") or 0,
                    reverse=True,
                )
                all_sessions = merged
                # Legacy single-session field = top of list.
                if all_sessions:
                    top = all_sessions[0]
                    session_info = {
                        "id": top["id"],
                        "source": top["source"],
                        "model": top["model"],
                        "started_at": top["started_at"],
                        "last_active": top["last_active"],
                    }
                    sid = top.get("id")
                    if sid:
                        # latest=True is CRITICAL: get_messages defaults to
                        # insertion order from the START (oldest 5 messages),
                        # which made the derived activity timestamps forever
                        # stale → StateMachine always evaluated .ready.
                        # latest=True pages back from the newest message and
                        # still returns chronologically ordered rows, so the
                        # "last processed = newest" rule in HermesWireActivity
                        # keeps working.
                        tail = db.get_messages(sid, limit=5, latest=True) or []
                        for m in tail:
                            recent_messages.append({
                                "role": m.get("role"),
                                "timestamp": m.get("timestamp"),
                                "tool_name": m.get("tool_name"),
                                "finish_reason": m.get("finish_reason"),
                                "is_reasoning": bool(
                                    (m.get("reasoning_content") or m.get("reasoning"))
                                    and m.get("role") == "assistant"
                                ),
                            })
                        # Tier A.3 — authoritative state derived from the
                        # session tail + live heartbeat. `tail` holds the
                        # FULL message rows (incl. tool_calls / reasoning),
                        # so no extra query is needed.
                        derived_state = _derive_state(
                            tail,
                            top.get("last_activity_at"),
                            time.time(),
                            True,
                        )
                        # Context usage — Hermes exposes no persisted "current
                        # window" counter (sessions.input_tokens is CUMULATIVE
                        # and was misused before → showed ~70% for a 2% real
                        # window). Replicate Hermes' own estimator on the live
                        # active messages so the % matches what Hermes itself
                        # reports (user: "ctx 只使用了 2%" was correct).
                        try:
                            from agent.model_metadata import (  # type: ignore
                                estimate_request_tokens_rough,
                                get_model_context_length,
                            )
                            live = db.get_messages(sid, include_compacted=False)
                            if live:
                                context_tokens = int(
                                    estimate_request_tokens_rough(
                                        live, system_prompt=""
                                    )
                                )
                                ctx_max = get_model_context_length(
                                    top.get("model") or "",
                                    base_url="",
                                    api_key="",
                                    provider=top.get("billing_provider") or None,
                                )
                                if ctx_max:
                                    context_max = int(ctx_max)
                        except Exception:
                            pass
                    else:
                        context_tokens, context_max = None, None
                        derived_state = _derive_state([], None, time.time(), True)
                else:
                    context_tokens, context_max = None, None
                    derived_state = _derive_state([], None, time.time(), False)
            finally:
                db.close()
        except Exception as e:
            error = (error + "; " if error else "") + f"session listing failed: {e}"

    cron_last, cron_id = _read_cron_last_fired()

    return {
        "v": 1,
        "ts": time.time(),
        "gateway": gateway_info,
        "session": session_info,
        # Tier B: every active session, not just the most recent.
        "sessions": all_sessions,
        "session_count": len(all_sessions),
        "state": derived_state if _IMPORT_ERROR is None else None,  # Tier A.3
        "approval": _read_pending_approval(),
        "cron": {
            "last_fired_at": cron_last,
            "recent_job_id": cron_id,
        },
        "context_tokens": context_tokens,
        "context_max": context_max,
        "skin": _read_current_skin(),
        "recent_messages": recent_messages,
        **({"_error": error} if error else {}),
    }


# ---------------------------------------------------------------------------
# Synthetic-frame helpers for the no-Hermes fallback
# ---------------------------------------------------------------------------

def _synthetic(error: str) -> dict[str, Any]:
    return {
        "v": 1,
        "ts": time.time(),
        "gateway": {"running": False, "manager": "(unavailable)", "pids": []},
        "session": None,
        "sessions": [],
        "session_count": 0,
        "state": None,
        "approval": {"pending": False, "prompt": None, "tool": None},
        "cron": {"last_fired_at": None, "recent_job_id": None},
        "context_tokens": None,
        "context_max": None,
        "skin": _read_current_skin(),
        "recent_messages": [],
        "_error": error,
    }


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def main() -> None:
    if _IMPORT_ERROR is not None:
        sys.stdout.write(json.dumps(_synthetic(_IMPORT_ERROR)) + "\n")
        sys.stdout.flush()
        return

    while True:
        try:
            frame = _collect()
            sys.stdout.write(json.dumps(frame, default=str) + "\n")
            sys.stdout.flush()
        except BrokenPipeError:
            return
        except Exception as e:
            sys.stderr.write(f"hermes_source loop error: {e}\n")
            sys.stderr.flush()
        time.sleep(INTERVAL_S)


if __name__ == "__main__":
    main()
