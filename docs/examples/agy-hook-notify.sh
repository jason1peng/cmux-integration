#!/usr/bin/env bash
# agy-hook-notify.sh - portable agy `PostInvocation` lifecycle hook.
# Copy to the machine-local path `~/bin/agy-hook-notify.sh` and review before use.
#
# Target product: the Antigravity-family `agy` CLI (observed as `agy 1.1.13`),
# which registers named hooks in `~/.gemini/config/hooks.json` and delivers
# camelCase JSON payloads on stdin (for example `transcriptPath`,
# `conversationId`, `invocationNum`) expecting a JSON object back on stdout.
#
# This adapter only:
#   1. validates the `PostInvocation` payload; `transcriptPath`,
#      `conversationId`, and an integer `invocationNum` are all required, and a
#      missing or invalid field aborts before anything is written;
#   2. fails closed when the declared transcript source is unreadable: no
#      result segment and no lifecycle event may claim success;
#   3. appends a bounded transcript tail to the machine-local result file
#      `${HOME}/agi-result.txt`, which is also the profile-declared transcript
#      source (the path is part of the contract, not an environment override);
#   4. appends one normalized lifecycle event line to the cmux-agent runtime
#      sink carrying stable invocation identity for correlation and dedupe;
#   5. returns an empty JSON object, which the agy hook stdout contract requires.
#
# `status: success` means only that this `PostInvocation` callback ran and
# captured fresh transcript data. It never proves task correctness; the
# supervisor still requires the correlated nonce-framed marker, artifact and
# focused checks, and idle cmux corroboration before accepting completion.
#
# Correlation split: the hook supplies `executor_session`, `conversation_id`,
# `event_id`, `transcript_path`, and `transcript_offset`. Supervisor-owned
# fields (`job_nonce`, `workspace`, `surface`, `cwd`) are bound through the
# active-job mapping recorded before launch, not invented here.
#
# It never approves tools, edits files on the operator's behalf, or grants
# permission. No private path is hard-coded here.
set -euo pipefail

: "${CMUX_AGENT_RUNTIME:?set the machine-local cmux-agent runtime directory}"

result_file="${HOME}/agi-result.txt"
sink="${CMUX_AGENT_RUNTIME}/events/agy-result.ndjson"
mkdir -p -- "$(dirname -- "$result_file")" "$(dirname -- "$sink")"

payload=$(cat)

# Validate the camelCase PostInvocation payload. Prints TAB-separated:
#   transcript_path, conversation_id, invocation_num
# A missing or malformed field exits non-zero before any file is touched.
meta=$(
  python3 -c '
import json
import sys

raw = sys.stdin.read()
if not raw.strip():
    raise SystemExit("empty agy hook payload")
payload = json.loads(raw)
if not isinstance(payload, dict):
    raise SystemExit("agy hook payload is not an object")


def required_text(key):
    value = payload.get(key)
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"agy hook payload is missing a non-empty {key}")
    return value.strip().splitlines()[0]


transcript_path = required_text("transcriptPath")
conversation_id = required_text("conversationId")
invocation_num = payload.get("invocationNum")
if isinstance(invocation_num, bool) or not isinstance(invocation_num, int):
    raise SystemExit("agy hook payload is missing an integer invocationNum")
print("\t".join((transcript_path, conversation_id, str(invocation_num))))
' <<<"$payload"
)

transcript_path=${meta%%$'\t'*}
rest=${meta#*$'\t'}
conversation_id=${rest%%$'\t'*}
invocation_num=${rest##*$'\t'}

# Fail closed without a success notification when the transcript source is gone.
if [[ ! -r "$transcript_path" ]]; then
  echo "[$(date -Iseconds)] agy hook: transcriptPath not readable: $transcript_path" >&2
  exit 1
fi

# agy resets invocationNum to 0 for every user turn (observed on 1.1.19), so
# conversationId + invocationNum alone collide across turns of one session.
# The transcript byte size at delivery is agy-owned, monotonic across turns,
# and unchanged by this adapter, which makes the triple below stable under a
# replayed notification yet distinct for each real turn.
transcript_size=$(wc -c <"$transcript_path" | tr -d '[:space:]')

# Record the fresh-segment start boundary (0 before the file exists), then
# capture the model-authored content from the recent transcript window.
# agy transcripts are JSONL whose `content` fields carry real newlines only
# after JSON decoding (markers arrive as \n escapes inside JSON strings), so
# appending raw lines would make the profile's adjacent-line nonce-framed
# marker rule impossible to satisfy. Decoding keeps the result segment as
# plain text and naturally excludes user-input/prompt-echo entries.
if [[ -e "$result_file" ]]; then
  transcript_offset=$(wc -c <"$result_file" | tr -d '[:space:]')
else
  transcript_offset=0
fi
python3 - "$transcript_path" >>"$result_file" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8", errors="replace") as stream:
        lines = stream.readlines()[-400:]
except OSError:
    raise SystemExit(1)
for line in lines:
    try:
        entry = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        continue
    if not isinstance(entry, dict):
        continue
    kind = str(entry.get("type", ""))
    source = str(entry.get("source", ""))
    # Model-authored output only: never user input, tool results, or echoes.
    if "RESPONSE" not in kind and "OUTPUT" not in kind and source != "MODEL":
        continue
    content = entry.get("content")
    if isinstance(content, str) and content.strip():
        sys.stdout.write(content.rstrip("\n") + "\n")
PY

# One correlated lifecycle event with stable identity for dedupe/replay checks.
event=$(
  python3 -c '
import json
import sys

conversation_id, invocation_num, transcript_size, transcript_path, transcript_offset = sys.argv[1:6]
event = {
    "hook_event_name": "PostInvocation",
    "hook": "agy-result-hook",
    "event_id": f"{conversation_id}:{invocation_num}:{transcript_size}",
    "executor_session": conversation_id,
    "conversation_id": conversation_id,
    "invocation_num": int(invocation_num),
    "transcript_size": int(transcript_size),
    "transcript_path": transcript_path,
    "transcript_offset": int(transcript_offset),
    "status": "success",
}
print(json.dumps(event, separators=(",", ":")))
' "$conversation_id" "$invocation_num" "$transcript_size" "$transcript_path" "$transcript_offset"
)

printf '%s\n' "$event" >>"$sink"

# The agy PostInvocation hook stdout contract requires a JSON object.
echo '{}'