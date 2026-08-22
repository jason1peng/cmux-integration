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
#    transcript, fully inside a disposable runtime.
runtime=$(mktemp -d "${TMPDIR:-/tmp}/cmux-agy-contract.XXXXXX")
transcript="$runtime/transcript.jsonl"
result_file="$runtime/agi-result.txt"
trap 'rm -rf "$runtime"' EXIT

# A candidate transcript tail that mirrors the agy transcript JSONL shape,
# including the nonce-framed completion marker in the final message.
nonce="agy-contract-nonce-001"
printf '%s\n' \
  '{"role":"user","display":"write agy-profile-proof.txt"}' \
  "{\"role\":\"assistant\",\"display\":\"<!-- CMX_JOB ${nonce} -->\"}" \
  '{"role":"assistant","display":"<!-- GOAL_COMPLETE -->"}' \
  >"$transcript"

# Adapter must emit {} and append a correlated lifecycle event plus a bounded
# transcript tail to the result file that the supervisor uses as its source.
stdout=$(
  printf '%s\n' '{"transcriptPath":"'"$transcript"'","conversationId":"conversation-agy-test","modelName":"auto"}' \
    | CMUX_AGENT_RUNTIME="$runtime" CMUX_AGENT_RESULT_FILE="$result_file" "$adapter"
)
[[ "$stdout" == '{}' ]]
grep -Fq '"hook_event_name":"PostInvocation"' "$runtime/events/agy-result.ndjson"
grep -Fq '"conversation_id":"conversation-agy-test"' "$runtime/events/agy-result.ndjson"
grep -Fq "\"transcript_path\":\"$transcript\"" "$runtime/events/agy-result.ndjson"
grep -Fq '"status":"success"' "$runtime/events/agy-result.ndjson"
[[ "$(wc -l < "$runtime/events/agy-result.ndjson")" -eq 1 ]]
tail -n 3 "$transcript" > "$runtime/expected-tail.txt"
diff -u "$runtime/expected-tail.txt" "$result_file" >/dev/null

# 3. Malformed / missing / non-object payloads fail closed (no event written,
#    no result append).
before_events=$(
  if [[ -s "$runtime/events/agy-result.ndjson" ]]; then
    wc -l < "$runtime/events/agy-result.ndjson"
  else
    echo 0
  fi
)
if printf '%s\n' '{"notTranscript":true}' \
  | CMUX_AGENT_RUNTIME="$runtime" CMUX_AGENT_RESULT_FILE="$result_file" "$adapter" 2>/dev/null; then
  echo 'agy adapter accepted a transcript-less payload' >&2
  exit 1
fi
if printf '%s\n' '[]' \
  | CMUX_AGENT_RUNTIME="$runtime" CMUX_AGENT_RESULT_FILE="$result_file" "$adapter" 2>/dev/null; then
  echo 'agy adapter accepted a non-object payload' >&2
  exit 1
fi
after_run=$(
  if [[ -s "$runtime/events/agy-result.ndjson" ]]; then
    wc -l < "$runtime/events/agy-result.ndjson"
  else
    echo 0
  fi
)
[[ "$before_events" -eq "$after_run" ]]

# 4. Adapter must not invent a marker: a transcript that never contains the
#    nonce-framed marker must not cause one. The fresh segment is append-only;
#    this is validated in the shared evidence contract, but confirm the adapter
#    does not read or inject result markers itself.
! grep -Eq 'CMX_JOB|GOAL_COMPLETE' "$wrapper" "$adapter"

# 5. Registration fragment is valid and points at the machine-local adapter
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

# 6. Installer installs the templates and merges registration without clobbering
#    unrelated hooks, in a disposable home.
case_home=$(mktemp -d "${TMPDIR:-/tmp}/cmux-agy-install.XXXXXX")
mkdir -p "$case_home/.gemini/config" "$case_home/bin"
printf '%s\n' '{"unrelated-hook":{"Stop":[{"type":"command","command":"/bin/true"}]}}' \
  > "$case_home/.gemini/config/hooks.json"
printf '#!/bin/sh\nexit 0\n' > "$case_home/bin/agy-with-permissions"
printf '#!/bin/sh\nexit 0\n' > "$case_home/bin/agy-hook-notify.sh"

# proceed, overwrite wrapper, overwrite adapter, merge hooks
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

# 7. No machine-specific secrets or private paths in any committed example.
! grep -rEq '/Users/|/home/|/private/|secret|token|bearer|api[_-]?key' "$examples"
# No absolute home path embedded in the profile or registration.
! grep -F -- '/Users' "$registration" "$examples/executor-profile.agy.json" "$wrapper" "$adapter" "$installer"

# 8. Docs provide the complete agy setup guide and reflect the released state
#    (no longer an uncommitted/pending-only integration).
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

echo 'agy executor focused contract: PASS'