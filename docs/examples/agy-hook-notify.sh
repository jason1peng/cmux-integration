#!/usr/bin/env bash
# agy-hook-notify.sh - portable agy `PostInvocation` lifecycle hook.
# Copy to the machine-local path `~/bin/agy-hook-notify.sh` and review before use.
#
# agy invokes this command after it reads (tool calls have finished). agy passes
# one JSON object on stdin and expects a JSON object back on stdout. Payload keys
# are camelCase (for example `transcriptPath`, `conversationId`).
#
# This adapter only:
#   1. validates the PostInvocation payload and requires a readable transcriptPath;
#   2. appends a bounded transcript tail to the machine-local result file used by
#      the cmux-agent supervisor as its transcript source;
#   3. appends one normalized lifecycle event line to the cmux-agent runtime sink
#      so the supervisor can wake and correlate validation; and
#   4. returns an empty JSON object, which the agy PostInvocation contract requires.
#
# It never approves tools, edits files on the operator's behalf, or grants
# permission. A missing, empty, non-object, or transcript-less payload fails
# closed (no event written, non-zero exit). No private path is hard-coded here.
set -euo pipefail

: "${CMUX_AGENT_RUNTIME:?set the machine-local cmux-agent runtime directory}"
result_file="${CMUX_AGENT_RESULT_FILE:-${HOME}/agi-result.txt}"
sink="${CMUX_AGENT_RUNTIME}/events/agy-result.ndjson"
mkdir -p -- "$(dirname -- "$result_file")" "$(dirname -- "$sink")"

payload=$(cat)

# Normalize and validate the payload. Emits exactly two lines:
#   line 1: the validated, stripped transcriptPath
#   line 2: the lifecycle event JSON
out=$(
  python3 -c '
import json
import sys

raw = sys.stdin.read()
if not raw.strip():
    raise SystemExit("empty agy hook payload")
payload = json.loads(raw)
if not isinstance(payload, dict):
    raise SystemExit("agy hook payload is not an object")
transcript_path = payload.get("transcriptPath")
if not isinstance(transcript_path, str) or not transcript_path.strip():
    raise SystemExit("agy hook payload is missing a non-empty transcriptPath")
transcript_path = transcript_path.strip().splitlines()[0]
conversation_id = payload.get("conversationId")
conversation_id = conversation_id if isinstance(conversation_id, str) and conversation_id.strip() else ""
event = {
    "hook_event_name": "PostInvocation",
    "hook": "agy-result-hook",
    "conversation_id": conversation_id,
    "transcript_path": transcript_path,
    "status": "success",
}
print(transcript_path)
print(json.dumps(event, separators=(",", ":"), ensure_ascii=True))
' <<<"$payload"
)

transcript_path=$(printf '%s\n' "$out" | head -n 1)
event=$(printf '%s\n' "$out" | sed -n '2p')

# Capture a bounded transcript tail into the result file so the supervisor can
# read a fresh appended segment. Tailing never modifies the transcript itself.
if [[ -n "$transcript_path" && -r "$transcript_path" ]]; then
  tail -n 200 -- "$transcript_path" >>"$result_file"
else
  echo "[$(date -Iseconds)] agy hook: transcriptPath not readable: $transcript_path" >&2
fi

# Append exactly one correlated lifecycle event for the supervisor push channel.
printf '%s\n' "$event" >>"$sink"

# The agy PostInvocation hook stdout contract requires a JSON object.
echo '{}'