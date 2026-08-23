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
trap 'rm -rf "$runtime"' EXIT

# A candidate transcript tail that mirrors the agy transcript JSONL shape,
# including the nonce-framed completion marker in the final message.
nonce="agy-contract-nonce-001"
printf '%s\n' \
  '{"role":"user","display":"write agy-profile-proof.txt"}' \
  "{\"role\":\"assistant\",\"display\":\"<!-- CMX_JOB ${nonce} -->\"}" \
  '{"role":"assistant","display":"<!-- GOAL_COMPLETE -->"}' \
  >"$transcript"

event_count() {
  if [[ -s "$sink" ]]; then wc -l <"$sink" | tr -d '[:space:]'; else echo 0; fi
}
result_bytes() {
  if [[ -e "$result_file" ]]; then wc -c <"$result_file" | tr -d '[:space:]'; else echo 0; fi
}
run_adapter() {
  printf '%s\n' "$1" | env HOME="$runtime" CMUX_AGENT_RUNTIME="$runtime" "$adapter"
}

valid_payload='{"transcriptPath":"'"$transcript"'","conversationId":"conversation-agy-test","invocationNum":3,"modelName":"auto"}'

# A valid payload emits {}, one lifecycle event, and a bounded fresh result tail.
stdout=$(run_adapter "$valid_payload")
[[ "$stdout" == '{}' ]]
[[ "$(event_count)" -eq 1 ]]
tail -n 3 "$transcript" >"$runtime/expected-tail.txt"
diff -u "$runtime/expected-tail.txt" "$result_file" >/dev/null

# The normalized event must carry the profile's full dedupe identity plus the
# hook-sourced correlation identity, with a stable event_id derived from the
# real agy conversation/invocation pair.
python3 - "$sink" "$transcript" <<'PY'
import json
import sys

sink, transcript = sys.argv[1], sys.argv[2]
events = [json.loads(line) for line in open(sink, encoding="utf-8") if line.strip()]
event = events[-1]
required = {
    "hook_event_name", "hook", "event_id", "executor_session",
    "conversation_id", "invocation_num", "transcript_path",
    "transcript_offset", "status",
}
missing = required - set(event)
assert not missing, f"event missing identity fields: {sorted(missing)}"
assert event["executor_session"] == event["conversation_id"] == "conversation-agy-test"
assert event["event_id"] == "conversation-agy-test:3"
assert event["transcript_path"] == transcript
assert event["transcript_offset"] == 0, "first capture must start at byte 0"
assert event["status"] == "success"
PY

# Replay: the identical payload re-presents the same stable identity so the
# supervisor can deduplicate it by event_id/executor_session, while each
# accepted capture advances the fresh-segment boundary.
before=$(event_count)
stdout=$(run_adapter "$valid_payload")
[[ "$stdout" == '{}' ]]
[[ "$(event_count)" -eq $((before + 1)) ]]
python3 - "$sink" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
assert events[-1]["event_id"] == events[0]["event_id"], "replay must keep a stable event_id"
assert events[-1]["transcript_offset"] != events[0]["transcript_offset"], (
    "each accepted capture must advance the fresh-segment boundary"
)
PY

# Stale/foreign session: a different conversation produces different identity.
run_adapter '{"transcriptPath":"'"$transcript"'","conversationId":"conversation-other-test","invocationNum":3}' >/dev/null
python3 - "$sink" <<'PY'
import json
import sys

events = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
assert events[-1]["executor_session"] == "conversation-other-test"
assert events[-1]["event_id"] != events[0]["event_id"], "a foreign session must not reuse identity"
PY

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
  '{"transcriptPath":"'"$runtime"'/missing-transcript.jsonl","conversationId":"conversation-agy-test","invocationNum":9}'; do
  if printf '%s\n' "$bad" | env HOME="$runtime" CMUX_AGENT_RUNTIME="$runtime" "$adapter" >/dev/null 2>&1; then
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
assert "agy-result-hook" in config
entry = config["agy-result-hook"]["PostInvocation"][0]
assert entry["command"].endswith("agy-hook-notify.sh")
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