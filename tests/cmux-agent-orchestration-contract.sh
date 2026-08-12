#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
skill="$root/skills/cmux-agent-orchestration/SKILL.md"
agent="$root/.pi/agents/cmux-agent-supervisor.md"

[[ -s "$skill" ]]
[[ -s "$agent" ]]

for marker in \
  '<!-- CMX_JOB <job_nonce> -->' \
  '<!-- GOAL_COMPLETE -->' \
  '<!-- NEED_APPROVAL -->' \
  '<!-- QUESTION -->' \
  '<!-- ERROR -->' \
  '<!-- STUCK -->'; do
  grep -Fq -- "$marker" "$skill"
done

for contract in \
  'agy-with-permissions' \
  'agy-hook-notify.sh' \
  'agy-result-hook' \
  'agi-result.txt' \
  'cmux-workspace' \
  'finite deadline' \
  'NEED_APPROVAL' \
  'tool-free checkpoint' \
  'same executor turn' \
  '--surface <executor-surface>' \
  'cryptographically random' \
  'same fresh appended segment' \
  'worktree_identity' \
  'pwd -P' \
  'cd -- <contract cwd> && exec ~/bin/agy-with-permissions'; do
  grep -Fq -- "$contract" "$skill"
done

# The supervisor must load the local skill and remain a thin, non-recursive child.
grep -Fq -- 'skills: cmux-agent-orchestration, cmux, cmux-workspace' "$agent"
grep -Fq -- 'maxSubagentDepth: 0' "$agent"
grep -Fq -- 'tools: read, grep, find, ls, bash' "$agent"
! grep -Fq -- 'tools: subagent' "$agent"

# The supervisor must not rely on focused-pane state or an unframed global transcript.
grep -Fq -- 'explicit executor surface' "$skill"
grep -Fq -- 'stale markers' "$skill"
grep -Fq -- 'tool-free checkpoint' "$skill"
grep -Fq -- 'executor must remain tool-free' "$skill"
grep -Fq -- 'git -C <cwd> rev-parse --show-toplevel' "$skill"

echo 'cmux-agent-orchestration contract: PASS'
