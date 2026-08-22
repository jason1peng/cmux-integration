#!/usr/bin/env bash
# Copy this template to the machine-local hook directory and review it before use.
# It only appends Cursor stop notifications; it does not approve tools or edit files.
set -euo pipefail

: "${CMUX_AGENT_RUNTIME:?set the machine-local cmux-agent runtime directory}"
sink="${CMUX_AGENT_RUNTIME}/events/cursor-stop.ndjson"
mkdir -p -- "$(dirname -- "$sink")"
payload=$(cat)

# Reject malformed/non-stop input instead of producing an ambiguous lifecycle event.
compact=$(
  python3 -c '
import json
import sys
payload = json.load(sys.stdin)
required = ("hook_event_name", "status", "transcript_path", "conversation_id", "generation_id", "session_id")
if not isinstance(payload, dict) or payload.get("hook_event_name") != "stop":
    raise SystemExit("expected Cursor stop hook event")
if any(not isinstance(payload.get(field), str) or not payload[field] for field in required):
    raise SystemExit("malformed Cursor stop hook event")
print(json.dumps(payload, separators=(",", ":")))
' <<<"$payload"
)
printf '%s\n' "$compact" >>"$sink"
