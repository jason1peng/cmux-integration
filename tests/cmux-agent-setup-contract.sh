#!/usr/bin/env bash
# Disposable contract for the explicit cmux-agent setup/check workflow.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
setup="$root/tools/cmux-agent-setup.sh"
[[ -x "$setup" ]]
command -v python3 >/dev/null

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/cmux-agent-setup-contract.XXXXXX")
trap 'rm -rf "$sandbox"' EXIT

home="$sandbox/home"
config="$sandbox/config"
profiles="$sandbox/profiles"
runtime="$sandbox/runtime"
bin_dir="$sandbox/bin"
fakebin="$sandbox/fakebin"
cursor_hooks="$home/.cursor/hooks.json"
agy_hooks="$home/.gemini/config/hooks.json"
mkdir -p "$home/.cursor" "$fakebin"
printf 'export KEEP_SETUP_TEST=1\n' >"$home/.bashrc"
cp "$home/.bashrc" "$sandbox/bashrc.before"

# Harmless fake executables make preflight deterministic; setup never invokes
# either one and never infers a profile from their presence.
for executable in agent agy; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$fakebin/$executable"
  chmod 755 "$fakebin/$executable"
done

cat >"$cursor_hooks" <<'JSON'
{
  "version": 1,
  "hooks": {
    "unrelated": [{"command": "keep-this-entry", "timeout": 2}]
  }
}
JSON

run_cursor() {
  env HOME="$home" PATH="$fakebin:$PATH" \
    CMUX_AGENT_HOME="$home" CMUX_AGENT_CONFIG="$config" \
    CMUX_AGENT_PROFILE_DIR="$profiles" CMUX_AGENT_RUNTIME="$runtime" \
    CMUX_AGENT_BIN="$bin_dir" CMUX_AGENT_CURSOR_HOOKS_CONFIG="$cursor_hooks" \
    "$setup" "$@"
}

run_agy() {
  env HOME="$home" PATH="$fakebin:$PATH" \
    CMUX_AGENT_HOME="$home" CMUX_AGENT_CONFIG="$config" \
    CMUX_AGENT_PROFILE_DIR="$profiles" CMUX_AGENT_RUNTIME="$runtime" \
    CMUX_AGENT_BIN="$bin_dir" CMUX_AGENT_HOOKS_CONFIG="$agy_hooks" \
    "$setup" "$@"
}

fail() {
  echo "cmux-agent-setup contract: $*" >&2
  exit 1
}

# 1. Default plan is read-only and explicitly names the selected profile.
plan="$sandbox/plan.txt"
run_cursor --profile cursor >"$plan"
grep -Fq 'Profile selection: cursor (explicit; no CLI auto-detection)' "$plan"
grep -Fq 'read-only plan' "$plan"
grep -Fq -- '--apply' "$plan"
[[ ! -e "$profiles/cursor.json" ]]
[[ ! -e "$runtime" ]]
cmp -s "$home/.bashrc" "$sandbox/bashrc.before"

# Profile selection is mandatory and never inferred from fake executables.
if "$setup" >"$sandbox/no-profile.txt" 2>&1; then fail 'missing --profile was accepted'; fi
if run_cursor --profile unknown >"$sandbox/bad-profile.txt" 2>&1; then fail 'unknown profile was accepted'; fi
run_cursor --profile both >"$sandbox/both-plan.txt"
grep -Fq 'Profile selection: both (explicit; no CLI auto-detection)' "$sandbox/both-plan.txt"

# 2. Explicit apply installs Cursor, the additive global user hooks, and the
# documented Pi resources.  A pre-existing unrelated hook survives unchanged.
printf 'y\ny\n' | run_cursor --profile cursor --apply --with-pi >"$sandbox/apply.txt"
[[ -x "$bin_dir/cursor-result-watcher.sh" ]]
[[ -x "$home/.cursor/hooks/cursor-transcript-bridge.sh" ]]
[[ -x "$home/.cursor/hooks/cursor-stop-notify.sh" ]]
[[ -f "$profiles/cursor.json" ]]
[[ ! -e "$bin_dir/cursor-advisor.sh" ]]
[[ ! -e "$bin_dir/cmux-agent-command-policy.py" ]]
[[ -f "$home/.pi/agent/agents/cmux-agent.md" ]]
[[ -f "$home/.pi/agent/skills/cmux-agent-orchestration/SKILL.md" ]]
grep -Fq 'skillPath: ../skills' "$home/.pi/agent/agents/cmux-agent.md"
grep -Fq 'skillPath: ../../skills' "$root/.pi/agents/cmux-agent.md"
python3 - "$profiles/cursor.json" "$bin_dir" "$runtime" "$cursor_hooks" <<'PY'
import json
import os
import sys

profile = json.load(open(sys.argv[1], encoding="utf-8"))
bin_dir, runtime, hooks = map(os.path.abspath, sys.argv[2:])
assert profile["watcher"]["command"] == os.path.join(bin_dir, "cursor-result-watcher.sh")
assert profile["watcher"]["advisor"]["command"] == os.path.join(bin_dir, "cursor-advisor.sh")
assert profile["watcher"]["advisor"]["command_policy"] == os.path.join(bin_dir, "cmux-agent-command-policy.py")
assert profile["lifecycle"]["hook_config"] == hooks
assert profile["transcript"]["source"].startswith(os.path.join(runtime, "jobs") + os.sep)
assert "${CMUX_AGENT_" not in json.dumps(profile)
assert "${HOME}" not in json.dumps(profile)
PY
python3 - "$cursor_hooks" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["hooks"]["unrelated"] == [{"command": "keep-this-entry", "timeout": 2}]
assert value["hooks"]["sessionStart"][0]["command"] == "hooks/cursor-transcript-bridge.sh"
assert value["hooks"]["stop"][0]["command"] == "hooks/cursor-stop-notify.sh"
assert value["hooks"]["stop"][1]["command"] == "hooks/cursor-transcript-bridge.sh"
assert all(".cursor/hooks" not in entry["command"] for event in value["hooks"].values() for entry in event if isinstance(entry, dict) and "command" in entry and entry["command"] in {"hooks/cursor-transcript-bridge.sh", "hooks/cursor-stop-notify.sh"})
PY
[[ -d "$runtime/jobs" && -d "$runtime/events" ]]
[[ -z "$(find "$runtime/jobs" -mindepth 1 -print -quit)" ]]
[[ ! -e "$home/agi-result.txt" ]]
[[ ! -e "$home/.gemini/config/hooks.json" ]]

# 3. Re-applying an identical setup is a no-op and does not require input.
run_cursor --profile cursor --apply --with-pi </dev/null >"$sandbox/idempotent.txt"
grep -Fq 'Already ready; no changes required.' "$sandbox/idempotent.txt"

# Optional advisor installation is explicit and includes the one authoritative
# policy helper; it is never pulled in by the base Cursor setup.
printf 'y\n' | run_cursor --profile cursor --apply --advisor >"$sandbox/advisor.txt"
[[ -x "$bin_dir/cursor-advisor.sh" ]]
[[ -x "$bin_dir/cmux-agent-command-policy.py" ]]

# 4. Conflicting or malformed Cursor hook JSON is rejected before mutation.
cp "$cursor_hooks" "$sandbox/hooks-good.json"
python3 - "$cursor_hooks" <<'PY'
import json
import sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["hooks"]["stop"][0]["timeout"] = 99
json.dump(value, open(path, "w", encoding="utf-8"), indent=2)
PY
if run_cursor --profile cursor >"$sandbox/conflict.txt" 2>&1; then fail 'conflicting Cursor hook entry was accepted'; fi
cp "$sandbox/hooks-good.json" "$cursor_hooks"
python3 - "$cursor_hooks" <<'PY'
import json
import sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["hooks"]["unrelated"] = ["not-a-hook-object"]
json.dump(value, open(path, "w", encoding="utf-8"), indent=2)
PY
if run_cursor --profile cursor --apply </dev/null >"$sandbox/malformed-entry.txt" 2>&1; then
  fail 'malformed unrelated Cursor hook entry was accepted'
fi
cp "$sandbox/hooks-good.json" "$cursor_hooks"
printf '{malformed\n' >"$cursor_hooks"
if run_cursor --profile cursor --check >"$sandbox/malformed.txt" 2>&1; then fail 'malformed Cursor hook JSON was accepted'; fi
cp "$sandbox/hooks-good.json" "$cursor_hooks"

# A target symlink is refused rather than followed or replaced.
symlink_root="$sandbox/symlink-case"
mkdir -p "$symlink_root/profiles" "$symlink_root/real"
ln -s "$symlink_root/real/cursor.json" "$symlink_root/profiles/cursor.json"
if env HOME="$symlink_root/home" PATH="$fakebin:$PATH" \
    CMUX_AGENT_HOME="$symlink_root/home" CMUX_AGENT_CONFIG="$symlink_root/config" \
    CMUX_AGENT_PROFILE_DIR="$symlink_root/profiles" CMUX_AGENT_RUNTIME="$symlink_root/runtime" \
    CMUX_AGENT_BIN="$symlink_root/bin" CMUX_AGENT_CURSOR_HOOKS_CONFIG="$symlink_root/home/.cursor/hooks.json" \
    "$setup" --profile cursor >"$sandbox/symlink.txt" 2>&1; then
  fail 'symlink target was accepted'
fi
[[ ! -e "$symlink_root/real/cursor.json" ]]

# --check is read-only, reports missing required files, and returns non-zero.
rm "$profiles/cursor.json"
if run_cursor --profile cursor --check >"$sandbox/check.txt" 2>&1; then fail 'incomplete check was reported ready'; fi
grep -Fq 'MISSING required file' "$sandbox/check.txt"
[[ ! -e "$profiles/cursor.json" ]]

# 5. Agy setup delegates wrapper/adapter/registration to the existing explicit
# installer.  It must not create a result placeholder or credentials.
printf 'y\ny\ny\n' | run_agy --profile agy --apply >"$sandbox/agy-apply.txt"
[[ -x "$bin_dir/agy-with-permissions" ]]
[[ -x "$bin_dir/agy-hook-notify.sh" ]]
[[ -f "$profiles/agy.json" ]]
[[ -f "$agy_hooks" ]]
[[ ! -e "$home/agi-result.txt" ]]
python3 - "$agy_hooks" "$bin_dir/agy-hook-notify.sh" "$profiles" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
entry = value["agy-result-hook"]["PostInvocation"][0]
import os
assert entry["command"] == os.path.abspath(sys.argv[2]), (entry["command"], sys.argv[2])
profile = json.load(open(os.path.join(sys.argv[3], "agy.json"), encoding="utf-8"))
agy_bin = os.path.dirname(os.path.abspath(sys.argv[2]))
assert profile["launch"]["command"] == os.path.join(agy_bin, "agy-with-permissions")
assert profile["lifecycle"]["adapter"] == os.path.abspath(sys.argv[2])
assert profile["lifecycle"]["hook_config"] == os.path.abspath(sys.argv[1])
assert "${HOME}" not in json.dumps(profile)
PY
run_agy --profile agy --apply </dev/null >"$sandbox/agy-idempotent.txt"
grep -Fq 'Already ready; no changes required.' "$sandbox/agy-idempotent.txt"
run_agy --profile agy --check >"$sandbox/agy-check.txt"
grep -Fq 'CHECK READY' "$sandbox/agy-check.txt"
cmp -s "$home/.bashrc" "$sandbox/bashrc.before"
[[ ! -e "$home/.zshrc" ]]
[[ -z "$(find "$runtime/jobs" -mindepth 1 -print -quit)" ]]

# No output from the setup plan/check may contain fixture secrets or file
# contents; only paths/statuses are printed.
if grep -Eqi 'fake-token|password|secret-value|BEGIN [A-Z ]+ PRIVATE KEY' "$sandbox"/*.txt; then
  fail 'sensitive fixture content leaked into setup output'
fi

echo 'cmux-agent-setup focused contract: PASS'
