#!/usr/bin/env bash
# Contract tests for the single authoritative bounded read-only command policy.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
validator="$root/tools/cmux-agent-command-policy.py"
[[ -x "$validator" ]]
command -v python3 >/dev/null
python3 -m py_compile "$validator"

# Keep the contract deterministic across developer machines. The execution
# boundary still inspects explicit repository config; ambient global/system
# helper settings must not change the ordinary allowlist fixtures.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
# The policy intentionally rejects ambient pager/helper variables. Clear the
# developer shell's display settings so ordinary allowlist fixtures remain
# deterministic; dedicated fixtures below set each unsafe helper explicitly.
unset PAGER LESS GIT_PAGER GIT_PAGER_IN_USE GIT_EXTERNAL_DIFF GIT_DIFF_OPTS

scope_args=(--scope README.md --scope .pi/agents/cmux-agent.md --scope tools/cmux-agent-timeline.py)

assert_result() {
  local expected=$1 cwd=$2 command=$3
  shift 3
  local output rc
  set +e
  output=$(python3 "$validator" validate --cwd "$cwd" "$@" --command "$command")
  rc=$?
  set -e
  python3 - "$output" "$expected" "$rc" <<'PY'
import json
import sys
value = json.loads(sys.argv[1])
expected, rc = sys.argv[2], int(sys.argv[3])
assert value["schema_version"] == 1
assert value["policy"] == "routine-command-v2"
assert value["decision"] == expected, value
assert (rc == 0) == (expected == "approve"), (value, rc)
PY
}

assert_approved() { assert_result approve "$@"; }
assert_rejected() { assert_result escalate "$@"; }

bundle="git status --short && echo '---' && git rev-parse HEAD && echo '---' && git diff --stat HEAD -- README.md .pi/agents/cmux-agent.md tools/cmux-agent-timeline.py"
set +e
bundle_result=$(python3 "$validator" validate --cwd "$root" --scope . --command "$bundle")
bundle_rc=$?
set -e
[[ "$bundle_rc" -eq 0 ]]
python3 - "$bundle_result" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
assert value["decision"] == "approve"
assert value["segments"] == 5
PY

assert_approved "$root" "grep -n literal README.md" "${scope_args[@]}"
assert_approved "$root" "sed -n '1,20p' README.md" "${scope_args[@]}"
assert_approved "$root" "head -c 20 README.md" "${scope_args[@]}"
assert_approved "$root" "head -n20 README.md" "${scope_args[@]}"
assert_approved "$root" "tail -n 20 README.md" "${scope_args[@]}"
# Oversized numeric text must fail through the canonical JSON path rather than
# leaking Python's integer-conversion traceback.
huge_head=$(printf '9%.0s' {1..5000})
assert_rejected "$root" "head -n${huge_head} README.md" --scope README.md
assert_approved "$root" "git log -1 -- README.md" "${scope_args[@]}"
assert_approved "$root" "git show HEAD -- README.md" "${scope_args[@]}"
assert_approved "$root" "git status --short" --scope .
assert_approved "$root" "git status --porcelain=v1" --scope .
# Optional Git option values must not consume a following path operand. This
# keeps the scope gate active for both bare options and out-of-scope paths.
assert_approved "$root" "git status --column" --scope .
assert_approved "$root" "git diff --color" --scope .
assert_rejected "$root" "git status --column /private/tmp/outside" --scope .
assert_rejected "$root" "git diff --color /private/tmp/outside" --scope .
assert_rejected "$root" "git status --porcelain=unsafe" --scope .
assert_rejected "$root" "git status --short" "${scope_args[@]}"
assert_approved "$root" "git branch --show-current" "${scope_args[@]}"
assert_approved "$root" "find . -maxdepth 1 -name README.md -print" --scope .
assert_approved "$root" "cat README.md" --scope README.md

# Explicit per-subcommand read-only rules reject branch mutation/upstream forms.
for command in \
  "git branch --" "git branch -m" "git branch -M" "git branch -d" "git branch -D" \
  "git branch --edit-description" "git branch --set-upstream-to origin/main" "git branch --move main" "git branch --copy main" \
  "git diff HEAD^ -- README.md" "git ls-files -- ':(exclude)README.md'" "cat README.md # comment" \
  "git branch -u origin/main" "git branch --unset-upstream" "git branch --track origin/main"; do
  assert_rejected "$root" "$command" "${scope_args[@]}"
done

# Shell expansion/control, stdin/follow, write/network, topology, and scope escapes.
for command in \
  "cat ~/.ssh/id_rsa" "cat {README.md,/etc/passwd}" "cat *.md" "echo !!" \
  "git diff HEAD" "git show HEAD" "git log -p" \
  "git status /private/tmp/outside" "git rev-parse HEAD:README.md" \
  "git status --short; rm -f README.md" "cat README.md | grep literal" \
  "git diff HEAD -- /private/tmp/outside" "git diff --output=out HEAD -- README.md" "git show --textconv HEAD -- README.md" \
  "git diff HEAD -- README.md && curl https://example.invalid" \
  'git diff HEAD -- README.md && echo "$HOME"' \
  "cat .env" "cat api_key.txt" "cat token.txt" "cat private_key.pem" "git show HEAD -- credentials.json" "rg password secrets/config" \
  "sed -i '1p' README.md" "sed -n '1,3{s/.*/id/e}' README.md" \
  "tail -f README.md" "tail --follow README.md" \
  "rg --follow literal README.md" "rg --hidden literal ." "rg --no-ignore literal ." "rg -L literal README.md" "grep -R literal README.md" \
  "ls -L README.md" "ls -lR ." "ls -HL ."; do
  assert_rejected "$root" "$command" "${scope_args[@]}"
done
assert_rejected "$root" "find . -exec rm -rf {} +" --scope .
assert_rejected "$root" "find . -delete" --scope .
assert_rejected "$root" "pwd && echo ok && git status --short && git rev-parse HEAD && git branch --show-current && git status --short && git rev-parse HEAD && git branch --show-current && pwd" "${scope_args[@]}"

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/cmux-command-policy.XXXXXX")
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/repo"
printf '%s\n' outside > "$sandbox/outside.txt"
ln -s ../outside.txt "$sandbox/repo/link.txt"
assert_rejected "$sandbox/repo" "cat link.txt" --scope link.txt
assert_rejected "$sandbox/repo" "cat ../outside.txt" --scope .

# A command-text allowlist is not an execution boundary by itself: local Git
# config can invoke external helpers while a plain read command is running.
# The authoritative validator must reject those configurations without ever
# invoking the configured helper. Keep one setting per fixture so each guard is
# exercised independently.
git_repo="$sandbox/configured-git-repo"
mkdir -p "$git_repo"
git -C "$git_repo" init -q
git_repo=$(cd "$git_repo" && pwd -P)
config_backup="$sandbox/configured-git-config.clean"
cp "$git_repo/.git/config" "$config_backup"
helper="$sandbox/configured-git-helper.sh"
helper_marker="$sandbox/configured-git-helper.marker"
cat > "$helper" <<'SH'
#!/usr/bin/env bash
printf '%s\n' invoked >> "${CMUX_POLICY_HELPER_MARK:?}"
exit 0
SH
chmod +x "$helper"
export CMUX_POLICY_HELPER_MARK="$helper_marker"

# First demonstrate the regression in a disposable checkout: the plain Git
# commands really do reach configured helpers. The policy check below must
# reject the same commands before an executor can run them.
printf '%s\n' before > "$git_repo/README.md"
git -C "$git_repo" add README.md
git -C "$git_repo" -c user.name=cmux-policy -c user.email=cmux-policy@example.invalid commit -qm fixture
printf '%s\n' after > "$git_repo/README.md"
git -C "$git_repo" config diff.external "$helper"
rm -f -- "$helper_marker"
(cd "$git_repo" && git diff -- README.md) >/dev/null 2>&1 || true
grep -Fq invoked "$helper_marker"
git -C "$git_repo" config --unset-all diff.external

# Diff-driver commands are selected by .gitattributes rather than appearing in
# the displayed command. Prove the ordinary `git diff` path reaches the helper
# in a disposable checkout, then require the policy preflight to reject it.
printf '%s\n' '*.txt diff=foo' > "$git_repo/.gitattributes"
printf '%s\n' before > "$git_repo/driver.txt"
git -C "$git_repo" add .gitattributes driver.txt
git -C "$git_repo" -c user.name=cmux-policy -c user.email=cmux-policy@example.invalid commit -qm driver-fixture
printf '%s\n' after > "$git_repo/driver.txt"
git -C "$git_repo" config diff.foo.command "$helper"
rm -f -- "$helper_marker"
(cd "$git_repo" && git diff -- driver.txt) >/dev/null 2>&1 || true
grep -Fq invoked "$helper_marker"
git -C "$git_repo" config --unset-all diff.foo.command

git -C "$git_repo" config core.fsmonitor "$helper"
rm -f -- "$helper_marker"
(cd "$git_repo" && git status --short) >/dev/null 2>&1 || true
grep -Fq invoked "$helper_marker"
git -C "$git_repo" config --unset-all core.fsmonitor

assert_config_rejected() {
  local key=$1 command=$2 expected=$3
  for setting in diff.external diff.foo.command core.fsmonitor core.pager core.hooksPath diff.foo.textconv filter.foo.clean include.path; do
    git -C "$git_repo" config --unset-all "$setting" 2>/dev/null || true
  done
  git -C "$git_repo" config "$key" "$helper"
  rm -f -- "$helper_marker"
  local output rc
  set +e
  output=$(python3 "$validator" validate --cwd "$git_repo" --scope . --command "$command")
  rc=$?
  set -e
  [[ "$rc" -eq 2 ]]
  python3 - "$output" "$expected" <<'PY'
import json, sys
value = json.loads(sys.argv[1])
assert value["decision"] == "escalate", value
assert value["category"] == "important", value
assert sys.argv[2] in value["reason"], value
PY
  [[ ! -e "$helper_marker" ]]
}

assert_config_rejected diff.external "git diff -- README.md" "diff.external"
assert_config_rejected diff.foo.command "git diff -- driver.txt" "diff driver command"
assert_config_rejected core.fsmonitor "git status --short" "core.fsmonitor"
assert_config_rejected core.pager "git status --short" "core.pager"
assert_config_rejected core.hooksPath "git status --short" "hooksPath"
assert_config_rejected diff.foo.textconv "git diff -- README.md" "diff textconv"
assert_config_rejected filter.foo.clean "git diff -- README.md" "filter helper"
# Git itself refuses to edit a config that includes a malformed shell helper,
# so restore a byte-for-byte clean config after this parser-only fixture.
assert_config_rejected include.path "git status --short" "Git includes"
cp "$config_backup" "$git_repo/.git/config"

# Explicit Git disabling options are accepted only for the helper class they
# actually disable; fsmonitor and hooks have no equivalent safe spelling and
# remain escalated.
git -C "$git_repo" config --no-includes --unset-all include.path 2>/dev/null || true
git -C "$git_repo" config --unset-all diff.external 2>/dev/null || true
git -C "$git_repo" config --unset-all diff.foo.textconv 2>/dev/null || true
git -C "$git_repo" config --unset-all core.pager 2>/dev/null || true
git -C "$git_repo" config --unset-all core.hooksPath 2>/dev/null || true
git -C "$git_repo" config core.fsmonitor false
assert_approved "$git_repo" "git --no-pager diff --no-ext-diff --no-textconv -- README.md" --scope .
assert_approved "$git_repo" "git --no-pager status --short" --scope .
git -C "$git_repo" config core.fsmonitor "$helper"
assert_rejected "$git_repo" "git --no-pager status --short" --scope .

# Environment-provided helpers and repository redirects are outside the
# inspectable config boundary and must fail closed as well.
rm -f -- "$helper_marker"
set +e
external_output=$(GIT_EXTERNAL_DIFF="$helper" python3 "$validator" validate --cwd "$git_repo" --scope . --command "git diff -- README.md")
external_rc=$?
set -e
[[ "$external_rc" -eq 2 ]]
grep -Fq 'GIT_EXTERNAL_DIFF' <<<"$external_output"
[[ ! -e "$helper_marker" ]]
set +e
redirect_output=$(GIT_DIR="$sandbox/repo/.git" python3 "$validator" validate --cwd "$git_repo" --scope . --command "git status --short")
redirect_rc=$?
set -e
[[ "$redirect_rc" -eq 2 ]]
grep -Fq 'repository environment overrides' <<<"$redirect_output"

printf '%s\n' 'cmux-agent command policy contract: PASS'
