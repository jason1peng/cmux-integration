#!/usr/bin/env bash
# agy-executor-contract.sh - focused contract tests for the portable agy wrapper,
# PostInvocation adapter, registration template, and the true result boundary.
#
# This is a disposable-only test: it exercises the templates under a temporary
# home/runtime directory and never touches the operator's real hooks, profiles,
# transcripts, or result file.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
examples="$root/docs/examples"
profiles_doc="$root/docs/executor-profiles.md"
readme="$root/README.md"
profile_json="$examples/executor-profile.agy.json"

# set -e ignores failures of !-negated commands, so negative assertions must
# fail explicitly instead of relying on `! grep`.
must_absent() {
  local flag="$1" pattern="$2"
  shift 2
  if grep "$flag" -q -- "$pattern" "$@"; then
    echo "forbidden content found: $pattern" >&2
    exit 1
  fi
}
wrapper="$examples/agy-with-permissions.sh"
adapter="$examples/agy-hook-notify.sh"
registration="$examples/agy-result-hook.hooks.json"
installer="$examples/agy-install.sh"

[[ -s "$wrapper" ]]
[[ -s "$adapter" ]]
[[ -s "$registration" ]]
[[ -s "$installer" ]]
[[ -x "$wrapper" ]]
[[ -x "$adapter" ]]
[[ -x "$installer" ]]

# 1. Wrapper contract: it must launch agy in the explicit dangerous mode and
#    forward arguments; it must not add or alter force/yolo by itself.
python3 - "$wrapper" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
exec_line = next(line for line in text.splitlines() if line.startswith("exec agy"))
assert exec_line == 'exec agy --dangerously-skip-permissions "$@"'
assert "--yolo" not in exec_line
assert "--force" not in exec_line
PY

# 2. PostInvocation adapter contract exercised against a synthetic payload and
#    transcript, fully inside a disposable runtime. The adapter resolves the
#    result file from HOME alone, so this test redirects HOME instead of any
#    override variable: the result path is part of the profile contract.
runtime=$(mktemp -d "${TMPDIR:-/tmp}/cmux-agy-contract.XXXXXX")
transcript="$runtime/transcript.jsonl"
result_file="$runtime/agi-result.txt"
sink="$runtime/events/agy-result.ndjson"
nonce="agy-contract-nonce-001"
job_dir="$runtime/jobs/$nonce"
mkdir -p "$job_dir"
trap 'rm -rf "$runtime"' EXIT

# The old model output is present before the supervisor's launch boundary. The
# fresh model output is appended only after the mapping is persisted; a valid
# adapter must never copy the old marker into the result source.
python3 - "$transcript" "$nonce" <<'PY'
import json
import sys

path, nonce = sys.argv[1], sys.argv[2]
entries = [
    {"step_index": 0, "source": "USER", "type": "USER_REQUEST", "status": "DONE",
     "content": f"Create proof.txt. Reply with:\n<!-- CMX_JOB {nonce} -->\n<!-- GOAL_COMPLETE -->"},
    {"step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE",
     "content": "<!-- CMX_JOB stale-nonce -->\n<!-- GOAL_COMPLETE -->"},
    {"step_index": 2, "source": "TOOL", "type": "TOOL_CALL_RESULT", "status": "DONE",
     "content": "file written"},
]
with open(path, "w", encoding="utf-8") as stream:
    for entry in entries:
        stream.write(json.dumps(entry) + "\n")
PY

# Persist the exact source identity/path and byte boundary before appending the
# fresh record. The normalized result has its own launch boundary as well.
python3 - "$job_dir/agy.mapping.json" "$runtime" "$nonce" "$transcript" "$result_file" <<'PY'
import json
import os
import sys
import time

mapping_path, runtime, nonce, transcript, result = sys.argv[1:]
source_stat = os.stat(transcript)
launch_ns = time.time_ns()
mapping = {
    "schema_version": 1,
    "job_nonce": nonce,
    "runtime": runtime,
    "source": {
        "path": transcript,
        "start_offset": source_stat.st_size,
        "launch_mtime_ns": source_stat.st_mtime_ns,
        "exists_at_launch": True,
        "created_after_launch": False,
        "device": source_stat.st_dev,
        "inode": source_stat.st_ino,
        "size_at_launch": source_stat.st_size,
        "mtime_ns_at_launch": source_stat.st_mtime_ns,
    },
    "result": {
        "path": result,
        "start_offset": 0,
        "launch_mtime_ns": launch_ns,
        "exists_at_launch": False,
        "created_after_launch": True,
    },
}
with open(mapping_path, "w", encoding="utf-8") as stream:
    json.dump(mapping, stream, separators=(",", ":"))
    stream.write("\n")
PY

printf '%s\n' '{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"<!-- CMX_JOB agy-contract-nonce-001 -->\n<!-- GOAL_COMPLETE -->"}' >>"$transcript"

event_count() {
  if [[ -s "$sink" ]]; then wc -l <"$sink" | tr -d '[:space:]'; else echo 0; fi
}
result_bytes() {
  if [[ -e "$result_file" ]]; then wc -c <"$result_file" | tr -d '[:space:]'; else echo 0; fi
}
run_adapter() {
  printf '%s\n' "$1" | env HOME="$runtime" CMUX_AGENT_RUNTIME="$runtime" CMUX_AGENT_JOB_RUNTIME="$runtime" CMUX_AGENT_JOB_NONCE="$nonce" "$adapter"
}

valid_payload='{"transcriptPath":"'"$transcript"'","conversationId":"conversation-agy-test","invocationNum":3,"modelName":"auto"}'

# The adapter must use the supervisor's per-job runtime binding, not an
# ambient/common runtime that happens to contain a similarly named job.
if printf '%s\n' "$valid_payload" | env HOME="$runtime" CMUX_AGENT_RUNTIME="$runtime/wrong-runtime" CMUX_AGENT_JOB_RUNTIME="$runtime" CMUX_AGENT_JOB_NONCE="$nonce" "$adapter" >/dev/null 2>&1; then
  echo "agy adapter accepted a mismatched common runtime" >&2
  exit 1
fi

# Mapping versions are strict integers; JSON booleans must not compare equal to
# version 1 under Python's bool/int equality rules.
python3 - "$job_dir/agy.mapping.json" <<'PY'
import json
import sys

path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["schema_version"] = True
with open(path, "w", encoding="utf-8") as stream:
    json.dump(value, stream, separators=(",", ":"))
    stream.write("\n")
PY
if run_adapter "$valid_payload" >/dev/null 2>&1; then
  echo "agy adapter accepted a boolean mapping schema version" >&2
  exit 1
fi
python3 - "$job_dir/agy.mapping.json" <<'PY'
import json
import sys

path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["schema_version"] = 1
with open(path, "w", encoding="utf-8") as stream:
    json.dump(value, stream, separators=(",", ":"))
    stream.write("\n")
PY

# A valid payload emits {}, one lifecycle event, and only the model record
# appended after the persisted launch boundary.
stdout=$(run_adapter "$valid_payload")
[[ "$stdout" == '{}' ]]
[[ "$(event_count)" -eq 1 ]]
python3 - "$result_file" <<'PY'
import sys

segment = open(sys.argv[1], encoding="utf-8").read()
assert segment == "<!-- CMX_JOB agy-contract-nonce-001 -->\n<!-- GOAL_COMPLETE -->\n", (
    "stale pre-launch completion markers must not be re-emitted"
)
assert "stale-nonce" not in segment
assert "file written" not in segment, "tool results must not be captured"
PY

# The normalized event carries the configured source identity, the source
# cursor, and a result-file offset that the completion gate can bind to its map.
python3 - "$sink" "$transcript" <<'PY'
import json, os, sys

sink, transcript = sys.argv[1], sys.argv[2]
events = [json.loads(line) for line in open(sink, encoding="utf-8") if line.strip()]
event = events[-1]
required = {
    "hook_event_name", "hook", "job_nonce", "event_id", "executor_session",
    "conversation_id", "invocation_num", "transcript_size",
    "transcript_path", "transcript_offset", "source_offset",
    "source_start_offset", "status",
}
missing = required - set(event)
assert not missing, f"event missing identity fields: {sorted(missing)}"
assert event["job_nonce"] == "agy-contract-nonce-001"
assert event["executor_session"] == event["conversation_id"] == "conversation-agy-test"
size = os.path.getsize(transcript)
assert event["transcript_size"] == size
assert event["event_id"] == f"agy-contract-nonce-001:conversation-agy-test:3:{size}"
assert event["transcript_path"] == os.path.realpath(transcript)
assert event["source_offset"] == size
assert event["source_start_offset"] < size
assert event["transcript_offset"] == 0
assert event["status"] == "success"
PY

# Replay: the declared identity remains stable and no source bytes or
# lifecycle evidence are re-emitted. The adapter itself suppresses the
# duplicate event, rather than relying on a downstream supervisor dedupe.
before=$(event_count)
bytes_before=$(result_bytes)
stdout=$(run_adapter "$valid_payload")
[[ "$stdout" == '{}' ]]
[[ "$(event_count)" -eq "$before" ]]
[[ "$(result_bytes)" -eq "$bytes_before" ]]
python3 - "$sink" "$profile_json" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
profile = json.load(open(sys.argv[2], encoding="utf-8"))
keys = profile["lifecycle"]["deduplicate_by"]
assert keys, "profile must declare a dedupe identity"

def identity(event):
    return tuple(event[key] for key in keys)

assert len(events) == 1, "replayed invocation must not append a second event"
assert events[-1]["source_offset"] == events[0]["source_offset"]
assert all(events[0].get(key) not in (None, "") for key in keys), (
    f"the event must expose its declared {keys} identity"
)
PY

# A crash after result append, event append, or state replacement leaves a
# durable pending transaction. The retry must recover it without duplicating
# normalized output or lifecycle evidence.
run_agy_crash_case() {
  local point=$1
  local case_runtime
  case_runtime=$(mktemp -d "${TMPDIR:-/tmp}/cmux-agy-crash-${point}.XXXXXX")
  case_runtime=$(cd "$case_runtime" && pwd -P)
  local case_nonce="agy-crash-${point}"
  local case_job="$case_runtime/jobs/$case_nonce"
  local case_source="$case_runtime/transcript.jsonl"
  local case_result="$case_runtime/agi-result.txt"
  mkdir -p "$case_job"
  : > "$case_source"
  python3 - "$case_job/agy.mapping.json" "$case_runtime" "$case_nonce" "$case_source" "$case_result" <<'PY'
import json, os, sys, time
_, mapping_path, runtime, nonce, source, result = sys.argv
source_stat = os.stat(source)
json.dump({
    "schema_version": 1,
    "job_nonce": nonce,
    "runtime": runtime,
    "source": {
        "path": source,
        "start_offset": 0,
        "launch_mtime_ns": source_stat.st_mtime_ns,
        "exists_at_launch": True,
        "created_after_launch": False,
        "device": source_stat.st_dev,
        "inode": source_stat.st_ino,
        "size_at_launch": 0,
        "mtime_ns_at_launch": source_stat.st_mtime_ns,
    },
    "result": {
        "path": result,
        "start_offset": 0,
        "launch_mtime_ns": time.time_ns(),
        "exists_at_launch": False,
        "created_after_launch": True,
    },
}, open(mapping_path, "w", encoding="utf-8"), separators=(",", ":"))
PY
  printf '%s\n' '{"source":"MODEL","type":"PLANNER_RESPONSE","content":"crash output"}' >> "$case_source"
  local payload='{"transcriptPath":"'"$case_source"'","conversationId":"crash-conversation","invocationNum":1}'
  if printf '%s\n' "$payload" | env HOME="$case_runtime" CMUX_AGENT_RUNTIME="$case_runtime" CMUX_AGENT_JOB_RUNTIME="$case_runtime" CMUX_AGENT_JOB_NONCE="$case_nonce" CMUX_AGENT_TEST_CRASH_AT="$point" "$adapter" >/dev/null 2>&1; then
    echo "agy crash injection did not interrupt at $point" >&2
    rm -rf "$case_runtime"
    exit 1
  fi
  [[ -e "$case_job/.agy-hook.pending.json" ]]
  # Also exercise repair of a process-died partial lifecycle append; the
  # staged event line and its sink offset make this safe and deterministic.
  if [[ "$point" == "after-event" ]]; then
    truncate -s $(( $(wc -c < "$case_runtime/events/agy-result.ndjson") - 1 )) "$case_runtime/events/agy-result.ndjson"
  fi
  printf '%s\n' "$payload" | env HOME="$case_runtime" CMUX_AGENT_RUNTIME="$case_runtime" CMUX_AGENT_JOB_RUNTIME="$case_runtime" CMUX_AGENT_JOB_NONCE="$case_nonce" "$adapter" >/dev/null
  [[ "$(wc -c < "$case_result" | tr -d '[:space:]')" -eq 13 ]]
  [[ "$(wc -l < "$case_runtime/events/agy-result.ndjson" | tr -d '[:space:]')" -eq 1 ]]
  [[ ! -e "$case_job/.agy-hook.pending.json" ]]
  rm -rf "$case_runtime"
}
for crash_point in after-result after-event after-state; do
  run_agy_crash_case "$crash_point"
done

# A hook-supplied path outside the configured mapping is rejected even when it
# contains plausible completion content.
foreign_transcript="$runtime/foreign-transcript.jsonl"
cp "$transcript" "$foreign_transcript"
foreign_payload='{"transcriptPath":"'"$foreign_transcript"'","conversationId":"conversation-agy-test","invocationNum":4}'
if run_adapter "$foreign_payload" >/dev/null 2>&1; then
  echo "agy adapter accepted an unbound hook transcript path" >&2
  exit 1
fi
[[ "$(event_count)" -eq $((before + 1)) ]]
[[ "$(result_bytes)" -eq "$bytes_before" ]]

# Stale/foreign session: a different conversation produces a different
# declared identity, so it is never mistaken for the active job's replay.
run_adapter '{"transcriptPath":"'"$transcript"'","conversationId":"conversation-other-test","invocationNum":3}' >/dev/null
# Cross-turn collision: agy resets invocationNum to 0 each user turn (observed
# on 1.1.19). A new turn with the same conversation and invocationNum but a
# grown transcript MUST produce a distinct declared identity.
printf '%s\n' '{"step_index":9,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"turn two"}' >>"$transcript"
run_adapter '{"transcriptPath":"'"$transcript"'","conversationId":"conversation-agy-test","invocationNum":3}' >/dev/null
python3 - "$sink" "$profile_json" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
keys = json.load(open(sys.argv[2], encoding="utf-8"))["lifecycle"]["deduplicate_by"]
def identity(event):
    return tuple(event[key] for key in keys)
foreign = events[-2]
turn_two = events[-1]
first = events[0]
assert foreign["executor_session"] == "conversation-other-test", "foreign session must be captured"
assert turn_two["conversation_id"] == first["conversation_id"]
assert turn_two["invocation_num"] == first["invocation_num"], "fixture must reproduce the per-turn reset"
assert identity(turn_two) != identity(first), "a new turn must not collide with an earlier one"
assert turn_two["source_offset"] > first["source_offset"]
PY

# A consumed transcript checkpoint must cover the entire prefix. Mutating a
# middle byte beyond both edge windows must fail before a duplicate callback
# can claim success.
large_payload='{"transcriptPath":"'"$transcript"'","conversationId":"conversation-agy-test","invocationNum":5}'
python3 - "$transcript" <<'PY'
import json
import sys

with open(sys.argv[1], "a", encoding="utf-8") as stream:
    stream.write(json.dumps({
        "step_index": 10,
        "source": "MODEL",
        "type": "PLANNER_RESPONSE",
        "content": "A" * 150000,
    }) + "\n")
PY
run_adapter "$large_payload" >/dev/null
[[ "$(wc -c <"$transcript" | tr -d '[:space:]')" -gt 131072 ]]
checkpoint_event_count=$(event_count)
checkpoint_result_bytes=$(result_bytes)

# A callback must reject an oversized fresh delta before materializing or
# appending any transcript/result data. Restore the source boundary afterward
# so the following checkpoint-integrity case remains independent.
bounded_source_size=$(wc -c <"$transcript" | tr -d '[:space:]')
python3 - "$transcript" <<'PY'
import sys

with open(sys.argv[1], "ab") as stream:
    stream.write(b"x" * (4 * 1024 * 1024 + 1))
PY
if run_adapter "$large_payload" >/dev/null 2>&1; then
  echo "agy adapter accepted an oversized fresh transcript delta" >&2
  exit 1
fi
[[ "$(event_count)" -eq "$checkpoint_event_count" ]]
[[ "$(result_bytes)" -eq "$checkpoint_result_bytes" ]]
truncate -s "$bounded_source_size" "$transcript"

python3 - "$transcript" <<'PY'
import sys

path = sys.argv[1]
data = bytearray(open(path, "rb").read())
offset = len(data) // 2
assert data[offset:offset + 1] == b"A", (offset, data[offset:offset + 1])
data[offset:offset + 1] = b"B"
with open(path, "wb") as stream:
    stream.write(data)
PY
if run_adapter "$large_payload" >/dev/null 2>&1; then
  echo "agy adapter accepted a middle-byte mutation in a consumed transcript" >&2
  exit 1
fi
[[ "$(event_count)" -eq "$checkpoint_event_count" ]]
[[ "$(result_bytes)" -eq "$checkpoint_result_bytes" ]]

# Replacing the configured source at the same path must fail closed rather than
# allowing a fresh-looking file to bypass the persisted launch identity.
bytes_before=$(result_bytes)
count_before=$(event_count)
replacement="$runtime/replacement-transcript.jsonl"
cp "$transcript" "$replacement"
mv -f "$replacement" "$transcript"
if run_adapter "$valid_payload" >/dev/null 2>&1; then
  echo "agy adapter accepted a replaced transcript source" >&2
  exit 1
fi
[[ "$(event_count)" -eq "$count_before" ]]
[[ "$(result_bytes)" -eq "$bytes_before" ]]

# 3. Fail-closed inputs: missing/malformed identity fields, non-object payloads,
#    and an unreadable transcript write no lifecycle event and no result bytes.
bytes_before=$(result_bytes)
count_before=$(event_count)
for bad in \
  '{"notTranscript":true}' \
  '[]' \
  '' \
  '{"transcriptPath":"'"$transcript"'","conversationId":"conversation-agy-test"}' \
  '{"transcriptPath":"'"$transcript"'","conversationId":"","invocationNum":3}' \
  '{"transcriptPath":"'"$transcript"'","conversationId":"conversation-agy-test","invocationNum":"three"}' \
  '{"transcriptPath":"'"$runtime"'/missing-transcript.jsonl","conversationId":"conversation-agy-test","invocationNum":9}' \
  '{"transcriptPath":"relative-transcript.jsonl","conversationId":"conversation-agy-test","invocationNum":9}'; do
  if printf '%s\n' "$bad" | env HOME="$runtime" CMUX_AGENT_RUNTIME="$runtime" CMUX_AGENT_JOB_RUNTIME="$runtime" CMUX_AGENT_JOB_NONCE="$nonce" "$adapter" >/dev/null 2>&1; then
    echo "agy adapter accepted an invalid payload: $bad" >&2
    exit 1
  fi
done
[[ "$(event_count)" -eq "$count_before" ]]
[[ "$(result_bytes)" -eq "$bytes_before" ]]

# 4. Profile/event coherence: every declared dedupe key is emitted, the
#    hook-sourced correlation keys are emitted, supervisor-owned keys stay in
#    the mapping (never claimed as hook fields), and the result path agrees.
python3 - "$profile_json" "$adapter" <<'PY'
import json
import sys
from pathlib import Path

profile = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
adapter_text = Path(sys.argv[2]).read_text()

dedupe = set(profile["lifecycle"]["deduplicate_by"])
emitted = {"event_id", "executor_session", "conversation_id", "transcript_path", "transcript_offset"}
assert dedupe <= emitted, f"profile dedupe keys not emitted by the adapter: {sorted(dedupe - emitted)}"

correlation = set(profile["lifecycle"]["correlation"])
assert "executor_session" in correlation
supervisor_owned = {"job_nonce", "workspace", "surface", "cwd"}
hook_claimed = json.dumps(sorted(emitted))
for key in sorted(supervisor_owned):
    assert f'"{key}"' not in hook_claimed, "supervisor-owned keys must not come from the hook"

source = profile["transcript"]["source"]
assert source == "${HOME}/agi-result.txt", source
assert '${HOME}/agi-result.txt' in adapter_text or '$HOME}/agi-result.txt' in adapter_text or 'agi-result.txt' in adapter_text
assert "CMUX_AGENT_RESULT_FILE" not in adapter_text, "the result path is contract-fixed, not an override"
mapping = profile["supervisor_mapping"]
assert mapping["required"] is True
assert mapping["file"].endswith("/jobs/${job_nonce}/agy.mapping.json")
assert "CMUX_AGENT_JOB_NONCE" in mapping["exports"]
assert "mapping source.path" in mapping["source_binding"]
assert "agy.mapping.json" in adapter_text
assert "last 400" not in adapter_text
assert "tail -n 400" not in adapter_text
assert "fresh_bytes" not in adapter_text
assert "output_chunks" not in adapter_text
assert "entries: list" not in adapter_text
for marker in (
    "MAX_TRANSCRIPT_DELTA_BYTES",
    "MAX_TRANSCRIPT_RECORD_BYTES",
    "MAX_TRANSCRIPT_RECORDS",
    "MAX_NORMALIZED_OUTPUT_BYTES",
    "readline",
    "agy-hook-output.",
):
    assert marker in adapter_text, f"bounded streaming safeguard missing: {marker}"
PY
must_absent -F 'CMUX_AGENT_RESULT_FILE' "$examples"/* "$readme" "$profiles_doc"

# 5. Adapter must not invent a marker: it never reads or injects result markers;
#    nonce framing stays in the shared evidence contract.
must_absent -E 'CMX_JOB|GOAL_COMPLETE' "$wrapper" "$adapter"

# 6. Registration fragment is valid and points at the machine-local adapter
#    through ~ so no home path is embedded in this repository.
python3 - "$registration" <<'PY'
import json
from pathlib import Path
import sys

reg = json.loads(Path(sys.argv[1]).read_text())
assert set(reg) == {"agy-result-hook"}
entry = reg["agy-result-hook"]["PostInvocation"][0]
assert entry["type"] == "command"
assert entry["timeout"] == 30
assert entry["command"] == "~/bin/agy-hook-notify.sh"
PY

# 7a. Installer merges registration without clobbering unrelated hooks when all
#     three overrides are explicit, in a disposable home.
case_home=$(mktemp -d "${TMPDIR:-/tmp}/cmux-agy-install.XXXXXX")
mkdir -p "$case_home/.gemini/config" "$case_home/bin"
printf '%s\n' '{"unrelated-hook":{"Stop":[{"type":"command","command":"/bin/true"}]}}' \
  >"$case_home/.gemini/config/hooks.json"
printf '#!/bin/sh\nexit 0\n' >"$case_home/bin/agy-with-permissions"
printf '#!/bin/sh\nexit 0\n' >"$case_home/bin/agy-hook-notify.sh"

printf 'y\ny\ny\ny\n' \
  | CMUX_AGENT_HOME="$case_home" CMUX_AGENT_BIN="$case_home/bin" \
      CMUX_AGENT_HOOKS_CONFIG="$case_home/.gemini/config/hooks.json" \
      bash "$installer" >/dev/null 2>&1

[[ -x "$case_home/bin/agy-with-permissions" ]]
[[ -x "$case_home/bin/agy-hook-notify.sh" ]]
diff -u "$wrapper" "$case_home/bin/agy-with-permissions" >/dev/null
diff -u "$adapter" "$case_home/bin/agy-hook-notify.sh" >/dev/null
python3 - "$case_home/.gemini/config/hooks.json" <<'PY'
import json
import sys

config = json.load(open(sys.argv[1], encoding="utf-8"))
assert "unrelated-hook" in config, "installer dropped an unrelated hook"
entry = config["agy-result-hook"]["PostInvocation"][0]
# The installer resolves the command to the actually installed adapter path,
# not the ~/ relative fragment form, so hook runtime HOME cannot misresolve it.
assert entry["command"] == sys.argv[1].replace("/.gemini/config/hooks.json", "/bin/agy-hook-notify.sh"), entry["command"]
PY
rm -rf "$case_home"

# 7b. Installer honors CMUX_AGENT_HOME alone: files land under that home and
#     nothing is written under the process HOME.
real_home=$(mktemp -d "${TMPDIR:-/tmp}/cmux-agy-realhome.XXXXXX")
target_home=$(mktemp -d "${TMPDIR:-/tmp}/cmux-agy-target.XXXXXX")
printf 'y\ny\n' | env HOME="$real_home" CMUX_AGENT_HOME="$target_home" bash "$installer" >/dev/null 2>&1
[[ -x "$target_home/bin/agy-with-permissions" ]]
[[ -x "$target_home/bin/agy-hook-notify.sh" ]]
diff -u "$wrapper" "$target_home/bin/agy-with-permissions" >/dev/null
[[ -f "$target_home/.gemini/config/hooks.json" ]]
python3 - "$target_home/.gemini/config/hooks.json" <<'PY'
import json
import sys

config = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(config) == {"agy-result-hook"}
entry = config["agy-result-hook"]["PostInvocation"][0]
# Staging install: the registered command must resolve to the SELECTED home's
# adapter, not to the process HOME via an unexpanded `~`.
expected = sys.argv[1].replace("/.gemini/config/hooks.json", "/bin/agy-hook-notify.sh")
assert entry["command"] == expected, entry["command"]
PY
[[ ! -e "$real_home/bin/agy-with-permissions" ]]
[[ ! -e "$real_home/bin/agy-hook-notify.sh" ]]
[[ ! -e "$real_home/.gemini/config/hooks.json" ]]
rm -rf "$real_home" "$target_home"

# 8. No machine-specific secrets or private paths in any committed example.
must_absent -E '/Users/|/home/|/private/|secret|token|bearer|api[_-]?key' "$examples"/*
must_absent -F '/Users' "$registration" "$profile_json" "$wrapper" "$adapter" "$installer"

# 9. Docs provide the complete agy setup guide and reflect the released state.
for doc in "$profiles_doc" "$readme"; do
  grep -Fqi -- 'agy' "$doc"
done
for section in \
  'agy setup' \
  'prerequisites' \
  'what this repository provides' \
  'must come from the local agy installation' \
  'required environment variables' \
  'PostInvocation hook registration' \
  'result-file setup' \
  'troubleshooting' \
  'dangerous'; do
  grep -Fqi -- "$section" "$profiles_doc"
done
grep -Fq -- 'invocationNum' "$profiles_doc"
grep -Fq -- 'event_id' "$profiles_doc"

echo 'agy executor focused contract: PASS'