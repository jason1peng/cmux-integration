#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
skill="$root/.agents/skills/cmux-agent/SKILL.md"
index="$root/docs/index.md"
design="$root/docs/headless-executor.md"

[[ -s "$skill" && -s "$index" && -s "$design" ]]

for contract in \
  'mode: headless' \
  'launch.input' \
  'cmux-agent' \
  'cmux-workspace' \
  'cmux new-pane --workspace' \
  'project name and next serial ordinal' \
  'shell=False' \
  'process-group' \
  'result.json' \
  'stdout.log' \
  'stderr.log' \
  'finite deadline' \
  'job_nonce' \
  'artifact' \
  'focused checks' \
  'calling agent independently' \
  'force' \
  'yolo' \
  'shell interpolation' \
  'POSIX/BSD/macOS-compatible' \
  'find <path> -type f -print' \
  'Python-based check' \
  '$HOME/.config/cmux-agent/profiles/cursor.json' \
  'assistant-authored' \
  '1,800 seconds (30 minutes)' \
  'No timeline view'; do
  grep -Fq -- "$contract" "$skill"
done

for obsolete in \
  'cursor-transcript-bridge' \
  'cursor-result-watcher' \
  'cursor-transcript-bootstrap' \
  'agy-hook-notify' \
  'agy-with-permissions' \
  'cmux-agent.timeline' \
  'tools/cmux-agent-timeline.py' \
  'cursor-hooks.json'; do
  if grep -RIn --exclude-dir=.git -- "$obsolete" "$skill" "$index"; then
    echo "obsolete interactive reference found: $obsolete" >&2
    exit 1
  fi
done

for path in \
  "$root/tools/cmux-agent-timeline.py" \
  "$root/tools/cmux-agent-command-policy.py" \
  "$root/adapters/cursor/cursor-transcript-bridge.sh" \
  "$root/adapters/cursor/cursor-result-watcher.sh" \
  "$root/adapters/agy/agy-hook-notify.sh"; do
  [[ ! -e "$path" ]] || { echo "obsolete path remains: $path" >&2; exit 1; }
done

# The reusable skill carries no host-specific subagent binding.
if grep -RIn --exclude-dir=.git -E 'maxSubagentDepth|skillPath:|systemPromptMode:' "$root/.agents/skills"; then
  echo 'host-specific agent binding found in reusable skills' >&2
  exit 1
fi

# The documentation entry point names the new source of truth and checks.
for text in \
  'docs/headless-executor.md' \
  'docs/executor-profiles.md' \
  'tools/cmux-agent-run.py' \
  'tests/cmux-agent-run-contract.sh' \
  '.agents/skills/cmux-agent/SKILL.md' \
  'timeline view'; do
  grep -Fqi -- "$text" "$index"
done

grep -Fq -- '33e7eb6' "$design"
grep -Fq -- '093951b' "$design"
"$root/tools/cmux-agent-run.py" --help >/dev/null

# Keep the worker workflow free of GNU-only find formatting predicates.
forbidden_find_format=$(printf '%s%s' '-' 'printf')
if grep -Fq -- "$forbidden_find_format" "$skill"; then
  echo 'non-portable find formatting found in the worker workflow' >&2
  exit 1
fi

# Exercise the portable file-enumeration form on the host running the contract.
portable_fixture=$(mktemp -d "${TMPDIR:-/tmp}/cmux-agent-portability.XXXXXX")
trap 'rm -rf "$portable_fixture"' EXIT
mkdir "$portable_fixture/nested"
printf '%s\n' root >"$portable_fixture/root.txt"
printf '%s\n' nested >"$portable_fixture/nested/nested.txt"
files=$(find "$portable_fixture" -type f -print | sort)
printf '%s\n' "$files" | grep -Fqx "$portable_fixture/root.txt"
printf '%s\n' "$files" | grep -Fqx "$portable_fixture/nested/nested.txt"

echo "cmux-agent contract: PASS"
