#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
sandbox=$(mktemp -d "${TMPDIR:-/tmp}/cmux-agent-setup.XXXXXX")
trap 'rm -rf -- "$sandbox"' EXIT

export HOME="$sandbox/home"
export CMUX_AGENT_HOME="$HOME"
export CMUX_AGENT_CONFIG="$sandbox/config"
export CMUX_AGENT_PROFILE_DIR="$CMUX_AGENT_CONFIG/profiles"
export CMUX_AGENT_RUNTIME="$sandbox/runtime"
export CMUX_AGENT_BIN="$sandbox/bin"
mkdir -p "$HOME"

# Plan and check are read-only, including their parent directories.
bash "$root/tools/cmux-agent-setup.sh" --profile cursor >"$sandbox/plan.txt"
[[ ! -e "$CMUX_AGENT_CONFIG" ]]
set +e
bash "$root/tools/cmux-agent-setup.sh" --profile cursor --check >"$sandbox/check-before.txt"
status=$?
set -e
[[ "$status" -eq 1 ]]
[[ ! -e "$CMUX_AGENT_CONFIG" ]]
[[ ! -e "$CMUX_AGENT_RUNTIME" ]]
grep -Fq -- 'headless runner' "$sandbox/plan.txt"
grep -Fq -- 'No Cursor/agy hooks' "$sandbox/plan.txt"

# Apply is explicit and installs only the profile, runner, and runtime dirs.
printf 'y\n' | bash "$root/tools/cmux-agent-setup.sh" --profile cursor --apply >"$sandbox/apply.txt"
[[ -x "$CMUX_AGENT_BIN/cmux-agent-run.py" ]]
[[ -f "$CMUX_AGENT_PROFILE_DIR/cursor.json" ]]
[[ -d "$CMUX_AGENT_RUNTIME/jobs" ]]
[[ ! -e "$CMUX_AGENT_RUNTIME/events" ]]
[[ ! -e "$HOME/.cursor/hooks.json" ]]
[[ ! -e "$HOME/.gemini/config/hooks.json" ]]

bash "$root/tools/cmux-agent-setup.sh" --profile cursor --check >"$sandbox/check-after.txt"
grep -Fq -- 'CHECK READY: selected setup is complete.' "$sandbox/check-after.txt"

# Existing symlink destinations are refused before a plan can write through them.
rm -rf -- "$CMUX_AGENT_PROFILE_DIR"
ln -s "$sandbox/elsewhere" "$CMUX_AGENT_PROFILE_DIR"
if bash "$root/tools/cmux-agent-setup.sh" --profile cursor --apply </dev/null >/dev/null 2>&1; then
  echo 'symlink profile directory unexpectedly accepted' >&2
  exit 1
fi

# Source and setup files contain no old hook/timeline installation references.
for obsolete in \
  'cursor-transcript-bridge' \
  'cursor-result-watcher' \
  'cursor-transcript-bootstrap' \
  'agy-hook-notify' \
  'agy-with-permissions' \
  'cmux-agent.timeline' \
  'cmux-agent-command-policy'; do
  if grep -RIn --exclude-dir=.git -- "$obsolete" "$root/tools/cmux-agent-setup.sh" "$root/adapters"; then
    echo "obsolete setup reference found: $obsolete" >&2
    exit 1
  fi
done

echo "cmux-agent setup contract: PASS"
