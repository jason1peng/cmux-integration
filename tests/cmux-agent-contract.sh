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

echo "cmux-agent contract: PASS"
