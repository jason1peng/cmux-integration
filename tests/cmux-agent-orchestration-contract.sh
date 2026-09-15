#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
skill="$root/skills/cmux-agent-orchestration/SKILL.md"
agent="$root/.pi/agents/cmux-agent.md"
index="$root/docs/index.md"
design="$root/docs/headless-executor.md"

[[ -s "$skill" && -s "$agent" && -s "$index" && -s "$design" ]]

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
  'main agent independently' \
  'force' \
  'yolo' \
  'shell interpolation' \
  'No timeline view'; do
  grep -Fq -- "$contract" "$skill"
done

for contract in \
  'cmux-agent workspace' \
  'fresh' \
  'headless CLI' \
  'cmux-agent-run.py' \
  'result.json' \
  'main agent must independently review' \
  'Never launch a nested subagent'; do
  grep -Fq -- "$contract" "$agent"
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
  if grep -RIn --exclude-dir=.git -- "$obsolete" "$skill" "$agent" "$index"; then
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

# The worker is deliberately not an orchestrator of other Pi subagents.
grep -Fq -- 'maxSubagentDepth: 0' "$agent"
if grep -Fq -- 'tools: subagent' "$agent"; then
  echo 'worker unexpectedly has subagent tooling' >&2
  exit 1
fi

# The documentation entry point names the new source of truth and checks.
for text in \
  'docs/headless-executor.md' \
  'docs/executor-profiles.md' \
  'tools/cmux-agent-run.py' \
  'tests/cmux-agent-run-contract.sh' \
  'timeline view'; do
  grep -Fqi -- "$text" "$index"
done

grep -Fq -- '33e7eb6' "$design"
grep -Fq -- '093951b' "$design"
"$root/tools/cmux-agent-run.py" --help >/dev/null

echo "cmux-agent orchestration contract: PASS"
