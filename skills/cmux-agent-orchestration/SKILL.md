---
name: cmux-agent-orchestration
description: Deterministically supervise an interactive executor in a cmux pane using transcript markers, explicit approvals, and bounded failure handling.
---

# Cmux agent orchestration

Use this skill when the main agent delegates a long-running interactive-agent job to a thin supervisor. The supervisor launches one executor in a persistent, visible cmux pane, observes its transcript, routes only explicit decision points, and returns artifacts and status. It must not perform the delegated work itself.

## Authority and safety

- The main agent owns the job, scope, approvals, and final result. The supervisor only launches, monitors, relays, and stops.
- Use dangerous mode for the first executor (`agy --dangerously-skip-permissions`) through the existing `~/bin/agy-with-permissions` wrapper. Do not invent another permission wrapper or build on the nonexistent `cmd-auto-approve.sh`.
- Dangerous mode removes OS permission prompts; it does **not** authorize content decisions. The executor must emit `<!-- NEED_APPROVAL -->` before any major, irreversible, spending, destructive, ambiguous, or scope-expanding action.
- `NEED_APPROVAL` is a tool-free checkpoint: emit the marker and stop/pause before invoking the consequential tool or action. Never emit the marker and perform the blocked action in the same executor turn; PostInvocation observation must occur before any consequential execution.
- Never infer state from an arbitrary terminal dump. The transcript hook is the source of truth. A pane is used for lifecycle/death detection and sending input only.
- Never silently answer a question, approve a marker, broaden scope, or retry forever. Escalate to the main agent.

## Job contract

The main agent supplies one self-contained job to the supervisor. Preserve the task text verbatim and include expected artifacts and a finite timeout.

```text
<CMUX_AGENT_JOB>
executor: agy
task: <exact delegated task>
expected_markers: GOAL_COMPLETE, NEED_APPROVAL, QUESTION, ERROR, STUCK
artifact_expectations: <paths or description>
cwd: <absolute executor working directory>
worktree_identity: <expected repository root and optional branch/ref>
timeout_seconds: <finite integer>
job_nonce: <fresh cryptographically random nonce>
</CMUX_AGENT_JOB>
```

The executor prompt must require a fresh nonce line immediately before the exact markers, and the markers themselves on their own output line:

```text
<!-- CMX_JOB <job_nonce> -->
<!-- GOAL_COMPLETE -->
```

The nonce is unique to this invocation and MUST NOT be reused from an earlier job.

| Marker | Meaning | Supervisor action |
| --- | --- | --- |
| `<!-- GOAL_COMPLETE -->` | Task finished | Capture the nonce-framed transcript segment and declared artifacts; return success. |
| `<!-- NEED_APPROVAL --> <what it wants to change>` | A consequential decision is blocked | Relay the complete request to the main agent; do not approve automatically. Send the main agent's explicit decision back to the executor using the explicit executor surface. |
| `<!-- QUESTION --> <question>` | Executor needs clarification | Relay verbatim to the main agent and wait for an answer. |
| `<!-- ERROR --> <details>` | Executor reported failure | Capture evidence, stop on the explicit executor surface, and report failure. |
| `<!-- STUCK --> <details>` | Executor cannot make progress | Stop on the explicit executor surface after capturing evidence and escalate; do not loop. |

If a marker is absent, the supervisor reports `RUNNING` only while the phase deadline remains. At the deadline, it reports timeout and follows the stop/escalate path. If multiple markers exist, apply the most conservative precedence: `ERROR`/`STUCK`, then `NEED_APPROVAL`, then `QUESTION`, then `GOAL_COMPLETE`.

## Pane and executor lifecycle

1. Reuse an existing dedicated executor pane when its identity and prior job are known; otherwise create one with the `cmux`/`cmux-workspace` skills. Do not reimplement pane discovery or control here.
2. Confirm the pane and its surface are alive before launch. Record stable workspace/pane/surface identifiers and the working directory. Every launch, input, approval response, and stop command MUST pass the recorded executor surface explicitly (for example, `--surface <executor-surface>`); never rely on whichever surface is focused.
3. Before launch, verify the executor surface's `pwd -P` equals the contract `cwd`. If the task is tied to a checkout, verify `git -C <cwd> rev-parse --show-toplevel` and the expected branch/ref match `worktree_identity`; stop and escalate on mismatch. Include the same cwd/worktree identity in the executor prompt.
4. Confirm the required wrapper and hook are executable. The launch MUST be cwd-bound, not a bare wrapper invocation: send a command equivalent to the following to the explicit executor surface, with `<contract cwd>` shell-quoted as one path:

   ```bash
   cd -- <contract cwd> && exec ~/bin/agy-with-permissions
   ```

   Re-check `pwd -P` and the worktree identity after establishing the cwd and before sending the executor prompt. If either check fails, stop and escalate rather than launching. The wrapper expands to `agy --dangerously-skip-permissions`; pass the executor prompt as its arguments/input using the existing cmux send controls.
5. Use the existing PostInvocation hook named `agy-result-hook`, configured as a **PostInvocation** hook, invoking `~/bin/agy-hook-notify.sh`. Its transcript source is `~/agi-result.txt`. Do not call it `cmux-auto-approve`, and do not treat it as a PreInvocation hook.
6. Generate a fresh cryptographically random `job_nonce` for every job. Require the executor to emit `<!-- CMX_JOB <job_nonce> -->` immediately before each lifecycle marker. Before launching, record the transcript file identity, byte offset, and modification time. Poll only bytes appended after that offset; if the file is truncated/replaced, stop and escalate rather than scanning old content. Accept a marker only when the current nonce appears in the same fresh appended segment immediately before it. This per-job framing prevents stale markers from a previous invocation in the global `~/agi-result.txt` from completing the new job.
7. Send the formatted job prompt to the executor surface using the explicit surface ID and start a monotonic deadline. Poll the transcript file with bounded intervals using file reads/stat; use screen reads only to detect pane loss or confirm that input was sent.
8. On completion, copy or reference the fresh job transcript segment and collect artifacts named by the executor. Do not report completion until the nonce-framed marker and expected artifact evidence are present.

## Monitoring and routing

Each poll must have a finite interval and the overall job must have a finite deadline. Track the last transcript size/mtime and the last marker observed. Silence is not success. A missing pane, dead process, unreadable transcript, malformed hook result, or unchanged transcript beyond the configured silence threshold is suspicious: stop the executor, capture evidence, and escalate once. A single safe relaunch may be proposed after a pane-loss failure, but never relaunch in an unbounded loop.

Route signals as follows:

| Observation | Decision |
| --- | --- |
| Routine progress and no marker | Let the executor continue until the deadline. |
| `NEED_APPROVAL` | Pause/hold the job, relay the requested change and evidence to the main agent, and wait for explicit approval or rejection. The executor must remain tool-free until the decision is returned. |
| `QUESTION` | Relay verbatim; do not answer based on supervisor guesswork. |
| `GOAL_COMPLETE` | Verify artifacts and return the result. |
| `ERROR`, `STUCK`, pane death, hook failure, or timeout | Stop safely, preserve transcript/screen evidence, and escalate once. |
| Destructive, irreversible, spending, ambiguous, or scope-expanding request without marker | Treat as a contract violation; stop and escalate rather than auto-running it. |

When approval or clarification arrives, send only the main agent's decision to the executor, record the response, and resume with a fresh bounded deadline. The approval response starts a new executor turn; do not treat the marker turn as permission to continue. A rejection ends the job as an escalated result. Do not expose executor internals to the main agent beyond the relevant marker, transcript excerpt, artifacts, and outcome.

## Result contract

Return a concise result containing:

- terminal state: `GOAL_COMPLETE`, `NEED_APPROVAL`, `QUESTION`, `ERROR`, `STUCK`, or `TIMEOUT`;
- executor, workspace/pane/surface, and transcript source;
- marker text and the relevant transcript excerpt;
- artifacts captured and any missing expected artifacts;
- approvals/questions requiring the main agent;
- elapsed time and whether a relaunch/stop occurred.

The supervisor must not claim success from an exit code alone. `GOAL_COMPLETE` without readable transcript evidence or expected artifacts is an incomplete result and must be escalated.

## Executor-agnostic seam

Keep the protocol independent of the executor. For future executors, replace only:

| Seam | agy implementation | Future implementation |
| --- | --- | --- |
| Launch command | `~/bin/agy-with-permissions` | Executor-specific dangerous-mode wrapper |
| Transcript source | `~/agi-result.txt` populated by `agy-result-hook` | Executor-specific PostInvocation/result source |
| Pane control | Existing `cmux`/`cmux-workspace` skills | Same |
| Job/marker/result contract | This document | Same unchanged |

Claude Code and multi-executor coordination are deferred; do not add them to the agy implementation.

## Verification scenarios

Exercise the contract with a disposable pane and bounded test jobs before relying on it:

1. A deterministic multi-step job reaches `GOAL_COMPLETE` and returns an artifact.
2. A job emits `NEED_APPROVAL` in a tool-free turn; the supervisor relays it and does not execute the blocked action before an explicit decision.
3. A job emits `QUESTION`; the question and answer round-trip without supervisor invention.
4. A silent, stuck, dead-pane, unreadable-hook, or timed-out job terminates and reports instead of looping.
5. A transcript containing stale markers does not complete a newly launched job.

Do not run destructive or spending scenarios as validation. Record the exact command, timeout, marker, artifact, and observed result for each live probe.
