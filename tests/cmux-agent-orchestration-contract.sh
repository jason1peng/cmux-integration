#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
skill="$root/skills/cmux-agent-orchestration/SKILL.md"
agent="$root/.pi/agents/agy.md"

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
  'cd -- <contract cwd> && exec ~/bin/agy-with-permissions' \
  'cmux-agent' \
  'cmux new-workspace --name cmux-agent' \
  '--cwd <contract cwd>' \
  'cmux new-pane --workspace <cmux-agent-workspace>' \
  'cmux rename-tab --surface <executor-surface> "<project_name> (<ordinal>)"' \
  'cmux send --workspace <cmux-agent-workspace> --surface <executor-surface>' \
  'project_name' \
  'authoritative working project/repository label, independent of worktree path' \
  'next available positive ordinal' \
  'cmux-integration (1)' \
  'Always create a new terminal pane/surface'; do
  grep -Fq -- "$contract" "$skill"
done

# The supervisor must load the local skill and remain a thin, non-recursive child.
grep -Fq -- 'name: agy' "$agent"
grep -Fq -- 'aliases: cmux-agent-supervisor' "$agent"
grep -Fq -- 'skills: cmux-agent-orchestration, cmux, cmux-workspace' "$agent"
grep -Fq -- 'maxSubagentDepth: 0' "$agent"
grep -Fq -- 'tools: read, grep, find, ls, bash' "$agent"
! grep -Fq -- 'tools: subagent' "$agent"

# The executor-ready gate must exist: never send the job prompt to an unready executor.
for gate in \
  'executor-ready gate' \
  'cmux read-screen' \
  'ready prompt' \
  'Never send the job prompt' \
  'bounded readiness deadline' \
  'do not guess an answer'; do
  grep -Fq -- "$gate" "$skill"
done
grep -Fq -- 'executor-ready gate' "$agent"

# Monitoring must combine push (transcript hook) and pull (pane screen) channels.
for hybrid in \
  'cmux read-screen --workspace <cmux-agent-workspace> --surface <executor-surface>' \
  'Classify the screen state' \
  '`idle`' \
  '`working`' \
  '`question`' \
  'is not completion'; do
  grep -Fq -- "$hybrid" "$skill"
done
grep -Fq -- 'push + pull' "$agent"

# Escalation discretion: routine TUI prompts may be self-handled, consequential ones must escalate.
for policy in \
  'Routine, non-consequential, and reversible' \
  'feedback surveys' \
  'safest option' \
  'MUST be recorded' \
  'trust/authorization' \
  'always escalate'; do
  grep -Fq -- "$policy" "$skill"
done
grep -Fq -- 'safest option' "$agent"
grep -Fq -- 'recorded in the result' "$agent"

# The supervisor must not rely on focused-pane state or an unframed global transcript.
grep -Fq -- 'explicit executor surface' "$skill"
grep -Fq -- 'stale markers' "$skill"
grep -Fq -- 'tool-free checkpoint' "$skill"
grep -Fq -- 'executor must remain tool-free' "$skill"
grep -Fq -- 'git -C <cwd> rev-parse --show-toplevel' "$skill"
! grep -Fq -- 'Reuse an existing dedicated executor pane' "$skill"
grep -Fq -- 'cmux-agent' "$agent"
grep -Fq -- 'new terminal pane/surface' "$agent"
grep -Fq -- 'authoritative `project_name` plus the next available ordinal' "$agent"
grep -Fq -- 'initialize it to the contract cwd before validation' "$agent"
! grep -Fq -- 'Derive `project_name` from the repository root basename' "$skill"
grep -Fq -- 'Before the pre-launch validation' "$skill"

echo 'cmux-agent-orchestration contract: PASS'
