#!/usr/bin/env bash
# Additive Cursor stop wakeup adapter.  It never approves work or declares
# completion; the supervisor owns the turn-settled gate.
set -euo pipefail

# Cursor reserves/overwrites CMUX_AGENT_RUNTIME for its own project state.
# Use the supervisor-owned per-job runtime when running inside Cursor hooks.
runtime="${CMUX_AGENT_JOB_RUNTIME:-${CMUX_AGENT_RUNTIME:-}}"
: "${runtime:?set the supervisor-generated per-job runtime}"
sink="${runtime}/events/cursor-stop.ndjson"
mkdir -p -- "$(dirname -- "$sink")"
payload=$(cat)
compact=$(
  python3 -c '
import json
import sys
value = json.load(sys.stdin)
if not isinstance(value, dict) or value.get("hook_event_name") != "stop":
    raise SystemExit("expected Cursor stop hook event")
status = value.get("status")
if not isinstance(status, str) or not status:
    raise SystemExit("malformed Cursor stop status")
identity = (value.get("conversation_id") or value.get("conversationId") or
            value.get("session_id") or value.get("sessionId"))
if not isinstance(identity, str) or not identity:
    raise SystemExit("malformed Cursor stop identity")
for key in ("transcript_path", "transcriptPath"):
    if key in value and value[key] is not None and not isinstance(value[key], str):
        raise SystemExit("malformed Cursor stop transcript path")
print(json.dumps(value, separators=(",", ":")))
' <<<"$payload"
)
printf '%s\n' "$compact" >>"$sink"
# Cursor command hooks require a valid JSON response.  This is a wakeup only.
printf '%s\n' '{}'
