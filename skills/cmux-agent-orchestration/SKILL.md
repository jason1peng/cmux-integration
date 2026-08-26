---
name: cmux-agent-orchestration
description: Deterministically supervise an interactive executor in a cmux pane using machine-local executor profiles, correlated lifecycle notifications, transcript markers, explicit approvals, and bounded failure handling.
---

# Cmux agent orchestration

Use this skill when the main agent delegates a long-running interactive-agent job to a thin supervisor. The supervisor resolves one explicitly configured executor profile, launches one executor in a persistent, visible cmux pane, observes its profile-declared lifecycle and result sources, routes only explicit decision points, and returns artifacts and status. It must not perform the delegated work itself.

## Authority and safety

- The main agent owns the job, scope, approvals, and final result. The supervisor only resolves/validates the profile, launches, monitors, relays, and stops.
- The job contract names an `executor_profile`; it never accepts a launch command, arbitrary argv, or permission mode from task text. Resolve only that explicit profile or the machine-local `CMUX_AGENT_EXECUTOR` default. There is no automatic CLI detection or fallback.
- A missing, malformed, unknown, non-executable, or unsafe profile fails closed before the job is sent. Do not silently create, install, repair, or select a profile.
- Dangerous permission modes are never implicit. A profile must declare its permission/trust choice, and the supervisor must surface a consequential trust/authorization decision instead of guessing. In particular, do not silently add force/yolo flags.
- Dangerous mode removes OS permission prompts; it does **not** authorize content decisions. The executor must emit `<!-- NEED_APPROVAL -->` before any major, irreversible, spending, destructive, ambiguous, or scope-expanding action.
- `NEED_APPROVAL` is a tool-free checkpoint: emit the marker and stop/pause before invoking the consequential tool or action. Never emit the marker and perform the blocked action in the same executor turn; lifecycle observation must occur before any consequential execution.
- Never infer completion from an arbitrary terminal dump. The profile-declared transcript/result source is authoritative; a pane is used for lifecycle/death detection, idle corroboration, and sending input only.
- Never silently answer a question, approve a marker, broaden scope, or retry forever. Escalate to the main agent.
- The supervisor may dismiss routine, non-consequential, reversible TUI prompts itself using the safest option (for example, skipping a feedback survey or declining a continue-previous-session prompt), but every such dismissal MUST be recorded. Consequential decisions — trust/authorization, authentication, spending, destructive, irreversible, ambiguous, or scope-expanding — always escalate.

## Executor-profile contract

Profiles are machine-local configuration, not repository state. The default location is `~/.config/cmux-agent/profiles/<profile-id>.json`; a machine may explicitly set `CMUX_AGENT_PROFILE_DIR`, but the supervisor must not search arbitrary locations. Repository examples are templates only. Never commit a personal profile, hook state, transcript, credential, or absolute home-directory path.

The resolver follows this order and fails closed:

1. Require the job's `executor_profile` when one is supplied and resolve only that profile ID.
2. Otherwise require `CMUX_AGENT_EXECUTOR` and resolve that ID from the configured machine-local profile directory.
3. Reject a missing selector, unknown ID, unsafe ID/path traversal, unreadable JSON, duplicate profile IDs, or an `executor`/launch command supplied inside task text. There is no installed-CLI auto-detection.

Before creating or launching a job, validate the selected profile as a strict object with the following fields. A profile may add only documented, schema-versioned fields; ambiguous or unknown launch/security fields fail closed rather than being ignored.

| Field | Required contract |
| --- | --- |
| `profile_id`, `schema_version` | ID matches the requested selector; supported schema version is explicit. |
| `launch.command`, `launch.argv`, `launch.mode` | Command is from trusted profile data, argv is an array, and mode is `interactive` or a separately validated `batch` adapter. Never interpolate task text. |
| `launch.permission_mode`, `launch.dangerous`, `launch.force`, `launch.yolo` | Permission/trust behavior is explicit. `force`/`yolo` cannot become true by default or by supervisor fallback. |
| `cwd.binding`, `cwd.canonicalize` | Binding is the contract cwd; canonicalize with `pwd -P`/`realpath` and report the normalized path. A profile cannot replace the requested cwd. |
| `probes.ready`, `probes.idle`, `probes.question` | Bounded screen probes identify readiness, idle, and questions. A question is not readiness. |
| `transport.prompt`, `transport.continuation` | Explicit input route, including the recorded cmux workspace/surface; no focused-pane or global routing. |
| `transcript.source`, `transcript.freshness`, `result.marker_rule` | Per-job or safely framed result source, fresh evidence boundary, and nonce/prompt-echo rule. |
| `lifecycle.event`, `lifecycle.source`, `lifecycle.required`, `lifecycle.correlation`, `lifecycle.acceptable_statuses`, `lifecycle.failure_statuses` | Declared event sink is available before launch; correlation and acceptable/error status rules are explicit. Lifecycle events wake validation but never prove completion. |
| `stop.mode`, `stop.deadline_seconds` | Explicit bounded stop/escalation behavior for the selected transport. |

Validate the command with an executable lookup or executable-file check, validate every declared source/sink and hook adapter before launch, and validate the canonical cwd and worktree. Do not modify an existing user hook or install a missing hook implicitly; a required unavailable lifecycle source is a pre-launch failure. Profile templates must document the explicit machine-local setup instead. When a hook payload does not carry supervisor fields such as `job_nonce`, `workspace`, or `surface`, correlate its executor session/conversation/generation and transcript identity against the mapping recorded for the active job; do not treat the absence of a raw nonce field as permission to skip correlation.

The shared protocol is deliberately independent of any CLI. A profile owns command/argv, permission and trust behavior, readiness/idle/question probes, prompt and continuation transport, transcript/result source, lifecycle-hook/event adapter, correlation fields, and stop behavior. The supervisor owns the common job, marker, approval, timeout, artifact, and completion contracts below.

## Job contract

The main agent supplies one self-contained job to the supervisor. Preserve the task text verbatim and include expected artifacts and a finite timeout.

```text
<CMUX_AGENT_JOB>
executor_profile: <explicit profile id, or omit only when CMUX_AGENT_EXECUTOR is configured>
task: <exact delegated task>
expected_markers: GOAL_COMPLETE, NEED_APPROVAL, QUESTION, ERROR, STUCK
artifact_expectations: <paths or description>
cwd: <absolute executor working directory>
project_name: <authoritative working project/repository label, independent of worktree path>
worktree_identity: <expected repository root and optional branch/ref>
timeout_seconds: <finite integer>
job_nonce: <fresh cryptographically random nonce>
</CMUX_AGENT_JOB>
```

The executor prompt must require a fresh nonce line immediately before the exact markers, and the markers themselves on their own output line. The nonce is unique to this invocation and MUST NOT be reused from an earlier job:

```text
<!-- CMX_JOB <job_nonce> -->
<!-- GOAL_COMPLETE -->
```

| Marker | Meaning | Supervisor action |
| --- | --- | --- |
| `<!-- GOAL_COMPLETE -->` | Task finished | Capture the nonce-framed fresh transcript/result segment, validate the shared completion gate, and collect declared artifacts. |
| `<!-- NEED_APPROVAL --> <what it wants to change>` | A consequential decision is blocked | Relay the complete request to the main agent; do not approve automatically. Send the main agent's explicit decision back through the explicit executor surface. |
| `<!-- QUESTION --> <question>` | Executor needs clarification | Relay verbatim to the main agent and wait for an answer. |
| `<!-- ERROR --> <details>` | Executor reported failure | Capture evidence, stop on the explicit executor surface, and report failure. |
| `<!-- STUCK --> <details>` | Executor cannot make progress | Stop on the explicit executor surface after capturing evidence and escalate; do not loop. |

If a marker is absent, report `RUNNING` only while the phase deadline remains. At the deadline, report timeout and follow the stop/escalate path. If multiple markers exist, apply the most conservative precedence: `ERROR`/`STUCK`, then `NEED_APPROVAL`, then `QUESTION`, then `GOAL_COMPLETE`.

## Pane and executor lifecycle

1. Enumerate workspaces with the official `cmux`/`cmux-workspace` skills and find the exact workspace named `cmux-agent`. Reuse that workspace when it exists; otherwise create it with `cmux new-workspace --name cmux-agent --description "Dedicated executor workspace" --cwd <contract cwd> --focus false`. Do not select a different workspace by focus or invent workspace-control logic.
2. Always create a new terminal pane/surface for every new executor job, even when reusing `cmux-agent`; never reuse a prior executor pane. Use `cmux new-pane --workspace <cmux-agent-workspace> --type terminal --direction right --focus false` and record the returned workspace/pane/surface identifiers.
3. Treat the job contract's `project_name` as authoritative; never derive the visible label from a temporary worktree basename. Enumerate surfaces in `cmux-agent` and choose the next available positive ordinal for that project, starting at 1. Label the new executor terminal surface with `cmux rename-tab --surface <executor-surface> "<project_name> (<ordinal>)"`, producing titles such as `cmux-integration (1)`, `cmux-integration (2)`, and `cmux-integration (3)`. Allocate labels serially; if a race creates a duplicate, keep surface IDs as the routing identity and reassign the later label before launch. A pane container has no independent name in cmux; its terminal surface/tab title is the project label.
4. Confirm the new pane and surface are alive before launch. Every launch, input, approval response, and stop command MUST pass the recorded executor workspace and surface explicitly (for example, `--workspace <cmux-agent-workspace> --surface <executor-surface>`); never rely on whichever workspace or surface is focused.
5. Before the pre-launch validation, initialize the new surface explicitly with `cmux send --workspace <cmux-agent-workspace> --surface <executor-surface> "cd -- <shell-quoted contract cwd>\n"`; fail closed if that setup command cannot be sent. The contract cwd MUST be shell-quoted as one path/word before it is inserted into the command string (for example, Bash `printf -- '%q' "$canonical_cwd"`, or an equivalent safe routine for the target shell); never interpolate a raw cwd. Then re-read the surface and verify its `pwd -P` equals the canonical contract `cwd`. If the task is tied to a checkout, verify `git -C <cwd> rev-parse --show-toplevel` and the expected branch/ref match `worktree_identity`; stop and escalate on mismatch. Include the same cwd, authoritative project name, selected ordinal, profile ID, and worktree identity in the executor prompt.
6. Resolve and validate the profile after the surface is initialized and before the launch. Re-check `pwd -P`, the worktree identity, executable, permission/trust declaration, prompt/continuation route, transcript/result source, required lifecycle sink, and stop behavior. If any check fails, stop and escalate rather than launching. The launch MUST be assembled only from the validated profile command and argv and sent to the explicit executor surface; every dynamically assembled `launch.command` and each `launch.argv` element MUST be shell-quoted individually, including empty values, before joining them into shell text. Build the equivalent of `cd -- <quoted-cwd> && exec <quoted-command> <quoted-argv...>` from separately quoted words (for example, `printf -- '%q' "$value"` or an equivalent safe routine); never use unquoted concatenation or `eval`. Task text cannot add flags or a command.
7. Establish the profile-declared lifecycle adapter and per-job transcript/result boundary before sending the job. Record source identity (file/device/event stream), byte offset or event cursor, and modification time where applicable. A missing or unreadable required hook/event source fails closed; never downgrade to screen-only polling. Do not modify existing user-level hooks.
8. Generate a fresh cryptographically random `job_nonce` for every job. Require the executor to emit `<!-- CMX_JOB <job_nonce> -->` immediately before each lifecycle marker. Before launching, record the transcript/result source identity, byte offset, and modification time. Poll only bytes appended after that offset (or events after the recorded cursor); if the source is truncated/replaced, stop and escalate rather than scanning old content. Accept a marker only when the current nonce appears in the same fresh appended segment immediately before it.
9. Run the executor-ready gate before sending the job prompt. Never send the job prompt to an executor that is still starting or is asking a consequential question. After launch, poll the executor surface screen with `cmux read-screen --workspace <cmux-agent-workspace> --surface <executor-surface>` at bounded intervals until the profile's ready prompt appears. If the executor instead shows a question/decision prompt, classify it. Routine, non-consequential, and reversible prompts (for example, feedback surveys, skip offers, or fresh-session confirmations such as "continue previous conversation?") may be dismissed by the supervisor with the safest option — for fresh-session confirmations, decline and start new — and every such dismissal MUST be recorded in the result. Consequential prompts (trust/authorization, authentication, spending, destructive, irreversible, ambiguous, or scope-expanding) are escalated to the main agent with a screen capture; do not guess an answer, and do not send the job past a consequential question. If readiness is not confirmed within a bounded readiness deadline, stop the executor and escalate rather than sending the prompt blind. A confirmed ready prompt is the only authorization to send the job prompt.
10. Send the formatted job prompt to the recorded executor workspace and surface using explicit IDs and start a monotonic deadline. Monitor with two complementary channels, each poll bounded: (a) push — the profile-declared lifecycle/transcript/result sources; and (b) pull — the executor surface screen via `cmux read-screen --workspace <cmux-agent-workspace> --surface <executor-surface>` for live pane state. Classify the screen state as `idle` (executor back at its ready prompt after a turn), `working` (banner or tool activity, not at the ready prompt), `question` (interactive prompt asking for a decision), or `lost` (pane/surface missing). Never send the job prompt while the screen shows `question`; never treat a `working` screen as idle.
11. On completion, copy or reference the fresh job transcript/result segment and collect artifacts named by the executor. Do not report completion until the shared completion gate passes.

## Shared completion gate

A lifecycle notification is a wake-up signal, not proof that the task succeeded. Accept `GOAL_COMPLETE` only when **all** of these checks pass:

1. The lifecycle event belongs to this job: its profile/event name is expected, status is in `acceptable_statuses`, no failure status (`error`, `aborted`, or equivalent) is present, and correlation fields match the active job's profile/session/conversation/generation/workspace and nonce mapping. A missing, malformed, stale, or unknown event fails closed.
2. The transcript/result source is fresh: it is the same source identity and fresh appended segment (or a new per-job source) captured after launch. The segment contains the current nonce-framed marker, with the nonce immediately before the marker. Reject prompt echo: a marker found only in the submitted prompt, reflected input, stale replay, stale markers, or an uncorrelated transcript is not evidence.
3. The requested artifact exists and is the expected change. Capture `git diff --check`, the relevant diff/status, and any task-declared focused checks; missing, unexpected, or malformed artifact evidence fails closed. Do not treat an exit code alone as proof.
4. The cmux surface is alive and idle at the profile's ready/follow-up probe after the response. A marker while the screen still shows `working`, a question, or a lost surface is not completion. Screen output is corroboration only; it cannot replace transcript/result evidence.
5. Repeated lifecycle events are deduplicated by the profile's executor session/generation/event identity. A repeated notification may wake validation again, but it cannot bypass any check; events from another job or a replayed generation are stale and rejected.

If any condition is false, return incomplete/escalated evidence rather than success. Hook events are repeatable lifecycle notifications, not task correctness.

## Monitoring and routing

Each poll must have a finite interval and the overall job must have a finite deadline. Track the last source size/mtime or event cursor and the last marker observed. Silence is not success. A missing pane, dead process, unreadable source, malformed lifecycle result, duplicate without fresh evidence, or unchanged source beyond the configured silence threshold is suspicious: stop the executor, capture evidence, and escalate once. A single safe relaunch may be proposed after a pane-loss failure, but never relaunch in an unbounded loop.

| Observation | Decision |
| --- | --- |
| Executor is still starting before the job prompt is sent | Do not send the job; wait only through the bounded readiness deadline, then capture the screen, stop, and escalate to the main agent. |
| Executor shows an unclassified or consequential question before the job prompt is sent | Capture the screen, do not answer, do not send the job, and escalate to the main agent. Routine, non-consequential, and reversible prompts are handled by the classification rule below. |
| Screen state `question` at any point (pre-job or mid-job) | Classify: routine/non-consequential/reversible (survey, skip, fresh-session confirmation) → dismiss with the safest option and record it; consequential (trust, authorization, authentication, spending, destructive, scope, ambiguity) → capture the screen and escalate, never guess. |
| Routine progress and no marker | Let the executor continue until the deadline. |
| `NEED_APPROVAL` | Pause/hold the job, relay the requested change and evidence to the main agent, and wait for explicit approval or rejection. The executor must remain tool-free until the decision is returned. |
| `QUESTION` | Relay verbatim; do not answer based on supervisor guesswork. |
| `GOAL_COMPLETE` | Treat as complete only when the nonce-framed marker, acceptable correlated lifecycle event, fresh transcript/result evidence, expected artifact/focused checks, and an `idle` screen after the response all pass. A marker while the screen still shows `working` is not completion. |
| `ERROR`, `STUCK`, lifecycle failure, pane death, hook/source failure, or timeout | Stop safely, preserve transcript/screen evidence, and escalate once. |
| Destructive, irreversible, spending, ambiguous, or scope-expanding request without marker | Treat as a contract violation; stop and escalate rather than auto-running it. |

When approval or clarification arrives, send only the main agent's decision to the executor, record the response, and resume with a fresh bounded deadline. The approval response starts a new executor turn; do not treat the marker turn as permission to continue. A rejection ends the job as an escalated result. Do not expose executor internals to the main agent beyond the relevant marker, transcript excerpt, artifacts, and outcome.

## Result contract

Return a concise result containing:

- terminal state: `GOAL_COMPLETE`, `NEED_APPROVAL`, `QUESTION`, `ERROR`, `STUCK`, or `TIMEOUT`;
- selected profile ID, dedicated workspace name/ref, project-labeled pane/surface, and profile-declared transcript/lifecycle sources;
- marker text, lifecycle status/correlation, and the relevant fresh transcript/result excerpt;
- artifacts captured and any missing expected artifacts;
- approvals/questions requiring the main agent;
- elapsed time, screen corroboration state, and whether a relaunch/stop occurred.

The supervisor must not claim success from an exit code, lifecycle event, or screen marker alone. `GOAL_COMPLETE` without readable fresh evidence, acceptable correlated status, expected artifacts/focused checks, and idle corroboration is incomplete and must be escalated.

## Interactive Cursor transcript bridge and turn-settled supervision

The supported Cursor profile in this slice is the original non-headless interactive `agent --trust` CLI in the explicitly routed cmux surface. Prompt submission is a TUI action: send the prompt through the recorded workspace/surface and use `ctrl+enter` to submit. The supervisor, not task text, owns the nonce, canonical cwd, workspace, surface, prompt, source boundary, and correlation mapping. Export the per-job runtime on `CMUX_AGENT_JOB_RUNTIME`; Cursor reserves/overwrites the common `CMUX_AGENT_RUNTIME` inside hook processes. Do not add `--print`, `--output-format`, `--force`, or `--yolo`.

The additive Cursor hook bridge is the only content adapter. It may be registered for `sessionStart`, `beforeSubmitPrompt`, `afterAgentThought`, `afterFileEdit`, `afterShellExecution`, `afterAgentResponse`, and `stop`. A hook is an asynchronous wakeup and identity/path observation, not proof of correctness. Early null or future `transcript_path` values are recorded as observations; the bridge captures the first usable path supplied by a correlated hook (or `CURSOR_TRANSCRIPT_PATH` fallback) only after the supervisor-owned mapping and fresh source boundary pass. It never scans undocumented Cursor directories. The hook-provided Cursor JSONL source is authoritative: normalize only fresh assistant/tool records after the source boundary, preserve source offsets, exclude user records and exact/segment prompt echoes, deduplicate semantic replay, and fail closed on malformed, stale, truncated, replaced, or uncorrelated input. If records expose session, conversation, generation, cwd, workspace, or surface identity, each must match the hook and supervisor mapping before filtering; a stop/error or aborted status latches the job failed and later callbacks cannot append result content. Screen text is never result content. The configured watcher is an explicit machine-local installation of `docs/examples/cursor-result-watcher.sh` at `${CMUX_AGENT_CONFIG}/bin/cursor-result-watcher.sh`; the supervisor never installs or repairs it implicitly.

`stop` and `afterAgentResponse` are optional wakeups. A present `stop` with `error` or `aborted` fails closed; an absent `stop` never downgrades transcript validation. The supervisor owns the **turn-settled** completion gate and accepts a result only when all of these are true: (1) fresh correlated normalized transcript content contains the current nonce immediately before the expected assistant marker; (2) declared artifact, `git diff --check`, and focused checks pass; (3) no approval/question is active; and (4) the explicitly targeted pane is alive at the normal follow-up/idle prompt. A marker in submitted input, prompt echo, or screen text alone is rejected.

The local watcher is the deterministic watcher and polling component: it repeatedly stats the exact per-job bridge result/event files, advances bounded byte cursors, and emits state changes only. Fresh correlated append activity emits `WORKING`. After five seconds without activity it reads the exact recorded cmux surface and emits `REQUIRE_ATTENTION` with bounded pane evidence; quiet is ambiguous and never completion. While quiet persists, pane reads are independently throttled to at most once per second. It may subsequently emit `QUESTION`, `IDLE`, `LOST`, or `UNKNOWN` as pane corroboration changes, but those classifications do not replace the LLM/supervisor decision or the turn-settled gate. It never sends an approval, answer, retry, or continuation. Missing/lost/question/unknown/attention state remains fail-closed until the supervisor revalidates the complete turn-settled gate.

An optional bounded local LLM advisor may be configured at `${CMUX_AGENT_CONFIG}/bin/cursor-advisor.sh`. The watcher invokes it only after fifteen seconds of quiet following fresh transcript/event activity, passing the current watcher state (`REQUIRE_ATTENTION` when applicable), bounded transcript evidence, and pane evidence. Calls use persisted 15/30/60-second backoff capped at 60 seconds; any new correlated activity resets the backoff. The strict JSON `routine-command-v1` response is a recommendation, not an approval. The supervisor may auto-approve only an exact displayed command that the watcher independently validates against the bounded read-only local allowlist (`pwd`, `ls`, `find`, `rg`, `grep`, `cat`, `head`, `tail`, `sed`, and read-only `git status`, `git diff`, `git log`, `git show`, `git rev-parse`, `git branch`, or `git ls-files`). Shell operators/substitution/chaining, unknown or non-exact commands, and mandatory escalation categories (`destructive`, `credential`, `deployment`, `external-network`, `ambiguous`, and `important`, including trust/authorization, authentication, spending, irreversible, or scope-expanding decisions) always escalate. The watcher overrides unsafe recommendations, and unavailable, timed-out, malformed, or otherwise invalid advisor output fails closed; advisor failure is fail-closed. The advisor never sends input to Cursor; every supervisor response still uses the recorded workspace/surface.

## Deferred transports

The common contract can describe `batch` or ACP transports, but no profile may claim them as complete until a dedicated adapter proves terminal-result, replay/deduplication, approval, cwd, and artifact semantics. Cursor batch (`--print --output-format stream-json`) and ACP (`agent acp`) remain documented follow-ups for this slice. A structured assistant event, reconnect, or replay is not a terminal result and must not be accepted as completion.

## Verification scenarios

Exercise each configured profile with a disposable pane and bounded harmless jobs before relying on it:

1. A deterministic multi-step job reaches `GOAL_COMPLETE` in a new project-labeled pane in the reused or newly created `cmux-agent` workspace and returns an artifact.
2. A second job reuses the same `cmux-agent` workspace but creates a different new pane/surface with the correct project label.
3. A job emits `NEED_APPROVAL` in a tool-free turn; the supervisor relays it and does not execute the blocked action before an explicit decision.
4. A job emits `QUESTION`; the question and answer round-trip without supervisor invention.
5. A silent, stuck, dead-pane, unreadable-hook/source, or timed-out job terminates and reports instead of looping.
6. A transcript containing stale markers does not complete a newly launched job.
7. A freshly launched executor that is still starting does not receive the job prompt; an unclassified or consequential question/decision state is captured and escalated, while a routine reversible prompt is classified and safely dismissed before readiness is rechecked.
8. The supervisor corroborates a pushed `GOAL_COMPLETE` marker with a pulled pane state showing the executor `idle`; a marker appearing while the screen is still `working` does not complete the job.
9. A routine, non-consequential TUI prompt (for example, a feedback survey) is dismissed with the safest option and recorded without escalation, while a consequential prompt (for example, a trust/authorization question) is escalated.
10. For a lifecycle-hook profile, an acceptable correlated event wakes validation, while `error`, `aborted`, stale, replayed, missing, or malformed events fail closed; a prompt-echo marker is rejected.

Do not run destructive or spending scenarios as validation. Record the exact command, timeout, profile, marker, artifact, and observed result for each live probe. Keep batch and ACP limitations documented rather than widening scope.
