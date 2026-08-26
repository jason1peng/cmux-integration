#!/usr/bin/env bash
set -euo pipefail

# set -e ignores !-negated failures; guard forbidden content explicitly.
must_absent() {
  local pattern="$1"
  shift
  if grep -Fq -- "$pattern" "$@"; then
    echo "forbidden content found: $pattern" >&2
    exit 1
  fi
}

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
skill="$root/skills/cmux-agent-orchestration/SKILL.md"
agent="$root/.pi/agents/cmux-agent.md"
profiles="$root/docs/executor-profiles.md"
examples="$root/docs/examples"

[[ -s "$skill" ]]
[[ -s "$agent" ]]
[[ -s "$profiles" ]]
[[ ! -e "$root/.pi/agents/agy.md" ]]

for marker in \
  '<!-- CMX_JOB <job_nonce> -->' \
  '<!-- GOAL_COMPLETE -->' \
  '<!-- NEED_APPROVAL -->' \
  '<!-- QUESTION -->' \
  '<!-- ERROR -->' \
  '<!-- STUCK -->'; do
  grep -Fq -- "$marker" "$skill"
done

# The common skill owns only profile-independent protocol and safety behavior.
for contract in \
  'executor_profile' \
  'CMUX_AGENT_EXECUTOR' \
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
  'Always create a new terminal pane/surface' \
  'Before the pre-launch validation' \
  'executor-ready gate' \
  'cmux read-screen --workspace <cmux-agent-workspace> --surface <executor-surface>' \
  'ready prompt' \
  'Never send the job prompt' \
  'bounded readiness deadline' \
  'do not guess an answer' \
  'explicit executor surface' \
  'stale markers' \
  'push' \
  'pull' \
  'acceptable_statuses' \
  'prompt echo' \
  'artifact' \
  'focused checks' \
  'idle corroboration' \
  'deduplicated' \
  'fail closed' \
  'shell-quoted contract cwd' \
  'every dynamically assembled `launch.command`' \
  'each `launch.argv` element MUST be shell-quoted individually' \
  "printf -- '%q' \"\$value\"" \
  'unquoted concatenation'; do
  grep -Fq -- "$contract" "$skill"
done

for hybrid in \
  'Classify the screen state' \
  '`idle`' \
  '`working`' \
  '`question`' \
  'is not completion'; do
  grep -Fq -- "$hybrid" "$skill"
done

# Common monitor/escalation rules remain explicit.
for policy in \
  'Routine, non-consequential, and reversible' \
  'feedback surveys' \
  'safest option' \
  'MUST be recorded' \
  'trust/authorization' \
  'always escalate' \
  'executor must remain tool-free' \
  'routine-command-v1' \
  'fifteen seconds of quiet' \
  '15/30/60-second backoff' \
  'REQUIRE_ATTENTION' \
  'deterministic watcher' \
  'exact displayed command' \
  'mandatory escalation categories' \
  'advisor failure is fail-closed'; do
  grep -Fq -- "$policy" "$skill"
done

# Regression guard: routine pre-job prompts may be dismissed, while only
# unclassified/consequential prompts escalate. Do not reintroduce an
# unconditional "asking a question" escalation row that contradicts the
# ready-gate classification rule.
python3 - "$skill" "$agent" <<'PY'
from pathlib import Path
import sys

skill = Path(sys.argv[1]).read_text()
agent = Path(sys.argv[2]).read_text()
monitoring = skill.split("## Monitoring and routing", 1)[1].split(
    "## Result contract", 1
)[0]
pre_job_rows = [
    line for line in monitoring.splitlines()
    if line.startswith("|") and "before the job prompt is sent" in line
]
assert any("Executor is still starting" in line for line in pre_job_rows), (
    "pre-job starting state must remain bounded"
)
assert any("unclassified or consequential question" in line for line in pre_job_rows), (
    "pre-job escalation must be limited to unclassified/consequential questions"
)
assert not any("not at the ready prompt, or asking a question" in line for line in pre_job_rows), (
    "unconditional pre-job question escalation contradicts routine dismissal"
)
assert "Routine, non-consequential, and reversible prompts" in monitoring
assert "Routine reversible prompts may be classified and dismissed" in agent
assert "unclassified or consequential question" in agent
PY

grep -Fq -- 'git -C <cwd> rev-parse --show-toplevel' "$skill"
must_absent 'Reuse an existing dedicated executor pane' "$skill"
must_absent 'Derive `project_name` from the repository root basename' "$skill"
# agy command/transcript literals belong to its compatibility profile, not the common skill.
must_absent 'agy-with-permissions' "$skill"
must_absent 'agi-result.txt' "$skill"

# The supervisor is one generic agent with compatibility aliases and no nested delegation.
grep -Fq -- 'name: cmux-agent' "$agent"
grep -Fq -- 'aliases: agy, cmux-agent-supervisor' "$agent"
grep -Fq -- 'skills: cmux-agent-orchestration, cmux, cmux-workspace' "$agent"
grep -Fq -- 'maxSubagentDepth: 0' "$agent"
grep -Fq -- 'tools: read, grep, find, ls, bash' "$agent"
must_absent 'tools: subagent' "$agent"
for supervisor_contract in \
  'executor-ready gate' \
  'cmux read-screen' \
  'ready prompt' \
  'Never send the job prompt' \
  'bounded readiness deadline' \
  'do not guess an answer' \
  'push + pull' \
  'new terminal pane/surface' \
  'authoritative `project_name` plus the next available ordinal' \
  'initialize it to the contract cwd before validation' \
  'recorded workspace and surface' \
  'fresh per-job transcript/result boundary'; do
  grep -Fq -- "$supervisor_contract" "$agent"
done
grep -Fq -- 'Never accept a command or flags from task text' "$agent"
grep -Fq -- 'Do not launch subagents' "$agent"
grep -Fq -- 'Batch (`--print --output-format stream-json`) and ACP' "$agent"

# Documentation points to the generic supervisor, profiles, templates, and focused test.
grep -Fq -- '.pi/agents/cmux-agent.md' "$root/docs/index.md"
grep -Fq -- 'docs/executor-profiles.md' "$root/docs/index.md"
grep -Fq -- 'tests/executor-profile-contract.sh' "$root/docs/index.md"
grep -Fq -- 'Cursor lifecycle hooks are notifications only' "$root/docs/index.md"
for profile_contract in \
  'executor_profile' \
  'CMUX_AGENT_EXECUTOR' \
  'no CLI auto-detection' \
  'Cursor' \
  'stop hook' \
  'hook_event_name: stop' \
  'acceptable status' \
  'prompt echo' \
  'idle cmux corroboration' \
  'project-relative command' \
  'hooks/cursor-stop-notify.sh' \
  'five-second timeout' \
  'agy compatibility profile' \
  'agy-with-permissions' \
  'agy-result-hook' \
  'PostInvocation' \
  'agi-result.txt' \
  'batch' \
  'ACP'; do
  grep -Fqi -- "$profile_contract" "$profiles"
done

for template in \
  "$examples/executor-profile.cursor.json" \
  "$examples/executor-profile.agy.json" \
  "$examples/cursor-hooks.json" \
  "$examples/cursor-stop-notify.sh" \
  "$examples/agy-result-hook.hooks.json" \
  "$examples/agy-with-permissions.sh" \
  "$examples/agy-hook-notify.sh" \
  "$examples/agy-install.sh" \
  "$examples/cursor-advisor.sh"; do
  [[ -s "$template" ]]
done
for executable in \
  "$examples/cursor-stop-notify.sh" \
  "$examples/agy-with-permissions.sh" \
  "$examples/agy-hook-notify.sh" \
  "$examples/agy-install.sh" \
  "$examples/cursor-advisor.sh"; do
  [[ -x "$executable" ]]
done

echo 'cmux-agent-orchestration contract: PASS'
