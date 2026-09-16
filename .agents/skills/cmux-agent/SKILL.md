---
name: cmux-agent
description: Run one explicitly configured headless coding CLI in a fresh cmux pane beside the caller, capture bounded process evidence, check the result, and report it to the calling agent.
---

# Cmux agent

Use this skill when a delegated worker must run Cursor, agy, or another coding
CLI in a visible cmux pane. The CLI is headless; the pane is only the execution
location and a human-visible diagnostic surface. Do not use pane text,
provider transcripts, hooks, or undocumented files as the result protocol.

## Ownership

- The calling agent owns the task, scope, approvals, review, and final decision.
- The worker owns one bounded execution and returns evidence to the calling agent.
- This skill owns cmux routing, explicit profile validation, process lifecycle,
  captured output, and the worker's first-pass artifact/check inspection.
- The worker must not launch another subagent or silently broaden the task.
- A worker report is evidence, not final approval; the calling agent reviews the
  actual worktree and repeats the important checks.

## Job contract

Accept only a self-contained job with an explicit profile and finite deadline:

```text
<CMUX_AGENT_JOB>
executor_profile: cursor
task: <exact implementation or review task>
cwd: <absolute working directory>
project_name: <stable repository/project label>
worktree_identity: <expected repository root and optional branch/ref>
artifact_expectations: <expected files or observable result>
focused_checks: <safe commands the worker may run after execution>
timeout_seconds: <positive finite integer>
job_nonce: <fresh cryptographically random identifier>
</CMUX_AGENT_JOB>
```

Reject a missing profile, missing cwd, missing project name, malformed job, task
text containing a replacement command/profile, non-finite timeout, reused
nonce, or ambiguous artifact expectation. The task text is input data, never
shell text or a source of flags.

## Profile contract

Profiles are machine-local JSON under `${CMUX_AGENT_PROFILE_DIR:-$HOME/.config/cmux-agent/profiles}`.
The setup CLI installs, by default, `cursor.json` at
`$HOME/.config/cmux-agent/profiles/cursor.json` (or the equivalent override).
Resolve exactly `<executor_profile>.json`; pass that resolved JSON path to the
runner. A bare profile ID such as `cursor` is not a runner profile path. Never
auto-detect a CLI or search other directories. A profile is valid only when it declares `mode: headless`
and a supported input mode, and contains:

| Field | Rule |
| --- | --- |
| `profile_id`, `schema_version` | The requested ID and supported schema `1`. |
| `launch.command`, `launch.argv` | Trusted profile-owned executable and fixed argument list. The runner may append the task only when `launch.input` is `prompt-arg`; it never appends flags. |
| `launch.mode` | Must be `headless`; interactive profiles are removed and rejected. |
| `launch.input` | Must be `stdin` or `prompt-arg`; the runner passes the task through a private descriptor or one argv value, never shell interpolation. |
| `sandbox`, `network`, `write_scope` | Required explicit execution boundaries. The checked-in profiles use enabled sandbox, enabled network for provider access, and `write_scope: ["cwd"]`; the worker never broadens them. |
| `launch.permission_mode` | Explicit human-reviewed permission/trust behavior. |
| `launch.dangerous`, `launch.force`, `launch.yolo` | Explicit booleans. No supervisor fallback enables them; `force`/`yolo` require `dangerous: true`. |
| `cwd` | `{ "binding": "contract", "canonicalize": "pwd -P" }`. |
| `result` | `format`, `completion: process-exit-and-marker`, `require_marker: true`, and artifact-check expectations. |
| `timeout_seconds` | Positive and bounded; the job timeout may be shorter. |
| `stop` | `mode: process-group` and a bounded termination deadline. |

A profile may represent any CLI. `cursor` is a sample profile using
`agent --print --output-format stream-json`; `agy` is a headless stdin profile
whose product-specific flags must be explicitly configured in the machine-local
copy. Do not claim a CLI is supported merely because its profile parses.

Headless permission behavior is consequential. Never add `--force`, `--yolo`,
`--dangerously-skip-permissions`, network access, credentials, or a new write
scope from task text. If the selected profile cannot safely express the
requested operation, fail closed and ask the calling agent for a decision.

## Execution procedure

1. Parse and validate the job. Canonicalize `cwd` with `pwd -P`/`realpath` and
   verify the requested repository root and branch/ref when
   `worktree_identity` is supplied. Generate or validate one fresh job nonce.
2. Create `${CMUX_AGENT_RUNTIME:-$HOME/.local/state/cmux-agent}/jobs/<job_nonce>`
   with restrictive permissions. Write a private task file containing the
   exact task followed by the required completion protocol:

   ```text
   At the end of the task, print these two lines in order:
   <!-- CMX_JOB <job_nonce> -->
   <!-- GOAL_COMPLETE -->
   ```

   Do not put the task in a shell command. Do not store credentials or extra
   prompt copies in the result metadata.
3. Use the existing `cmux` and `cmux-workspace` skills to resolve the
   invoking caller's workspace and terminal surface. Prefer the explicit
   `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID` anchors supplied by cmux. Verify
   them with an explicitly targeted `cmux list-panes --workspace
   <caller-workspace> --json --id-format both`. If either anchor is missing,
   call `cmux identify --json` once and use its `caller.workspace_ref`,
   `caller.pane_ref`, and `caller.surface_ref` fields—not `focused`—and report
   that fallback. If a supplied anchor is present but verification fails,
   fail closed; do not fall back to `identify`. If the caller surface is
   absent from the workspace, fail closed; never substitute a focused
   workspace or surface. Never silently use the visually focused workspace.

   Create the executor in that same workspace by splitting the caller surface
   in one additive command:

   ```text
   cmux new-split right --workspace <caller-workspace> --surface <caller-surface> --focus false
   ```

   This creates one fresh terminal surface in a different pane beside the
   caller and avoids the unused default pane created by a new workspace. Do
   not create, select, or route to a separate workspace/window. Record the
   caller workspace and returned executor surface, then label the executor
   surface with the authoritative project name and next serial ordinal, for
   example `cmux-integration (2)`. Resolve the executor pane by listing the
   caller workspace and matching the returned executor surface in
   `surface_refs`/`surface_ids`; do not assume the creation acknowledgement
   includes a pane ID. Never route by focus or a pane title.
4. Initialize the executor surface with an explicitly targeted, safely quoted
   `cd -- <cwd>` command and verify `pwd -P` and worktree identity. A `cmux
   send` acknowledgement is not proof that the command ran.
5. Resolve the machine-local profile, the installed runner, and the installed
   result waiter. Use
   `${CMUX_AGENT_RUNNER:-${CMUX_AGENT_CONFIG:-$HOME/.config/cmux-agent}/bin/cmux-agent-run.py}`
   and
   `${CMUX_AGENT_WAIT:-${CMUX_AGENT_CONFIG:-$HOME/.config/cmux-agent}/bin/cmux-agent-wait.py}`.
   Both must be executable reviewed copies of the corresponding repository
   tools; the runner performs no shell evaluation and the waiter performs no
   process termination. Pass the resolved absolute profile path (for example
   `$HOME/.config/cmux-agent/profiles/cursor.json`), not only `cursor`. Validate
   the profile again immediately before launch.
6. Launch the runner in the recorded surface with every dynamic shell word
   quoted individually:

   ```text
   cd -- <quoted-cwd> && exec <quoted-runner>
     --profile <quoted-profile>
     --task-file <quoted-task-file>
     --job-dir <quoted-job-dir>
     --job-nonce <quoted-job-nonce>
     --workspace <quoted-caller-workspace>
     --surface <quoted-executor-surface>
     --cwd <quoted-cwd>
     --timeout-seconds <quoted-timeout>
   ```

   The runner starts the configured command with `shell=False`, passes the task
   using the profile's declared input mode, mirrors output to the pane, captures
   `stdout.log` and `stderr.log`,
   and writes `result.json`. It enforces the shorter of the job and profile
   deadlines; `--timeout-seconds` cannot extend the profile cap. The supplied
   Cursor profile allows up to 1,800 seconds (30 minutes), and the setup CLI
   must be rerun after changing the checked-in template.
   The child receives `CMUX_AGENT_JOB_NONCE`, `CMUX_AGENT_JOB_DIR`,
   `CMUX_AGENT_WORKSPACE`, `CMUX_AGENT_SURFACE`, and `CMUX_AGENT_CWD`. Never use
   `eval`, unquoted concatenation, or `env ... exec`.
7. Invoke the installed waiter with the exact result identity and expected
   nonce:

   ```text
   <quoted-waiter> --result-path <quoted-job-dir>/result.json
     --job-nonce <quoted-job-nonce> --poll-interval-seconds 1
     --safety-margin-seconds 5
   ```

   The waiter reads only the atomically replaced per-job `result.json`. It
   validates schema, exact job nonce, exact result path, timing metadata, and
   status. Only `completed`, `failed`, `timed_out`, and `cancelled` are
   terminal; `starting` and `running` remain non-terminal. Its fence is the
   runner-owned `deadline_at_ns` plus `stop_deadline_seconds` plus the explicit
   safety margin. A terminal manifest is returned even when its status is
   failure; inspect that status rather than treating a waiter exit code alone
   as task success. A non-terminal job is reported incomplete after the fence.
   The waiter never reads pane text, provider state, transcripts, task text, or
   output captures, and it never cancels or terminates a process. Normal
   supervision must not cancel a healthy job because a poll interval elapsed;
   an operator-directed cancellation is considered only after the fence and
   still requires a terminal manifest or an explicit missing-evidence report.
   The pane may be read only to diagnose a missing/dead runner. Do not install
   hooks, scan provider transcript directories, or start a watcher.
8. Keep the Cursor profile's full 1,800-second cap; the finalization reserve
   belongs to the outer worker/host deadline and must not shorten that profile
   cap. Before that outer deadline, reserve the final 2–5 minutes for a durable
   finalization checkpoint. Record the result path and manifest status, the
   expected artifact and focused-check evidence, output hashes or a bounded
   file list as applicable, the canonical cwd/worktree identity, and direct
   `git status`/diff evidence. After recording that checkpoint, stop
   exploratory calls and only complete the report or escalate missing,
   malformed, or unresolved evidence.
9. When the waiter reports a terminal state, inspect the declared artifact and
   run only the safe focused checks named by the job. Focused checks run in the
   executor's environment, so use POSIX/BSD/macOS-compatible command forms;
   do not use GNU-only `find` formatting predicates. For file enumeration,
   prefer `find <path> -print` (or `find <path> -type f -print` when only
   regular files matter), or use a small Python-based check when basenames,
   depth, or structured output is needed.
   If a named check is not supported by the host, report the failed check and
   escalate rather than silently substituting a platform-specific command.
   Verify the expected file contents, repository status/diff, and check exit
   codes directly. A CLI exit code, completion marker, or waiter terminal
   observation alone is insufficient. If the executor requests approval, asks
   an unresolved question, emits an error, or attempts work outside scope, stop
   and relay the request to the calling agent; never answer or approve by
   guessing.
10. Return a concise report to the calling agent containing the terminal status,
   profile ID, job nonce, caller workspace, executor pane/surface, canonical
   cwd, result path, stdout/stderr paths and hashes, elapsed time, exit status,
   marker observation,
   artifact evidence, focused-check results, and any limitation or escalation.
   The calling agent independently performs the final review and verification. Do not claim
   success when the artifact/check evidence is missing.

## Result contract

`result.json` is runner-owned metadata, not executor-authored content. It has
one final status from `completed`, `failed`, `timed_out`, or `cancelled`, plus:

- job/profile/workspace/surface/cwd identity (the worker report also includes
  the executor pane returned by cmux);
- start/end timestamps and duration;
- child PID and exit code;
- task hash (not task text);
- stdout/stderr paths, sizes, and SHA-256 hashes;
- `marker_observed`, which is only a hint that the captured output contained
  the nonce and terminal marker. For `stream-json`, only assistant-authored
  text events count, so an echoed user prompt cannot satisfy it; and
- timeout, cancellation, and termination information; and
- runner-owned `timeout_seconds`, `deadline_at_ns`, and
  `stop_deadline_seconds` timing metadata. The waiter uses these fields for its
  deadline + process-stop-grace + safety-margin fence and never edits the
  manifest.

The raw captures are optional diagnostics and may contain model output. Keep
them machine-local, do not copy them into source control, and do not treat
them as an authorization or correctness decision. The calling agent must inspect
only the bounded evidence needed for the task and independently validate the
worktree.

## Failure handling

- Missing/malformed profile, unavailable command, unsafe permission declaration,
  invalid cwd/worktree, missing runner, or invalid job: fail before execution.
- Non-zero child exit: report `failed`, even if a marker or partial artifact
  exists.
- Timeout: the runner terminates the child process group within the profile
  stop deadline, writes `timed_out`, and preserves captures. The waiter waits
  through the runner deadline, stop grace, and safety margin before reporting
  incomplete evidence; it does not add a second cancellation mechanism.
- Pane loss or missing result metadata: report incomplete evidence; do not infer
  success from the visible pane.
- Approval/question/error/scope issue: stop, preserve result paths, and escalate
  to the calling agent. Do not retry indefinitely or switch profiles.

No timeline view is part of this transport. The final result manifest and raw
stdout/stderr captures are sufficient for the normal headless path. Add a
structured event log only if a later requirement demonstrates a real need for
multi-step or long-lived orchestration diagnostics.
