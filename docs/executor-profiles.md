# Machine-local executor profiles

CMX-003 makes the cmux supervisor independent of the CLI installed on a particular machine. The supervisor is the generic `.pi/agents/cmux-agent.md` agent. `agy` and `cmux-agent-supervisor` remain aliases for that one agent; they are not separate supervisors.

The profile is the only place that selects an executable, permission/trust mode, input transport, transcript/result source, lifecycle event, and stop behavior. Profiles and hook state are machine-local. Do not commit a real profile, a transcript, a credential, a socket/event queue, or a user hook to this repository.

## Selection and setup

The supervisor resolves profiles in this order:

1. An explicit `executor_profile` in the `<CMUX_AGENT_JOB>` contract.
2. `CMUX_AGENT_EXECUTOR`, when the job omits `executor_profile`.
3. No fallback. Missing or unknown selection fails before the prompt is sent.

There is no CLI auto-detection. Task text cannot provide a command, argv, executable path, or permission flag. Configure a profile directory explicitly when the default is not suitable:

```bash
mkdir -p "$HOME/.config/cmux-agent/profiles" \
         "$HOME/.cursor/hooks" \
         "$HOME/.local/state/cmux-agent/jobs"
export CMUX_AGENT_CONFIG="$HOME/.config/cmux-agent"
export CMUX_AGENT_PROFILE_DIR="$CMUX_AGENT_CONFIG/profiles"
export CMUX_AGENT_RUNTIME="$HOME/.local/state/cmux-agent"
export CMUX_AGENT_EXECUTOR=cursor       # an explicit operator choice, not detection
```

Copy one of the templates in `docs/examples/` to the machine-local profile directory, replace only the documented placeholders, and validate the executable and hook sink before using it. For the Cursor profile, copy `docs/examples/cursor-stop-notify.sh` to `$HOME/.cursor/hooks/cursor-stop-notify.sh` and merge the stop registration into the supported user hook file `$HOME/.cursor/hooks.json` using the command `hooks/cursor-stop-notify.sh` with `timeout: 5` (the user-hook working directory is `$HOME/.cursor`). Preserve unrelated existing hooks; do not overwrite the file. The checked-in `docs/examples/cursor-hooks.json` is instead a project-local disposable template: copy the adapter to `.cursor/hooks/cursor-stop-notify.sh` and merge that template's `.cursor/hooks/cursor-stop-notify.sh` command into the project's `.cursor/hooks.json`. Do not use the project-relative command in the user hook file, and do not use the user-relative command in a project hook file. Hook command paths are resolved by Cursor from the selected hook location; they are not `${CMUX_AGENT_CONFIG}` placeholder expansions. Profile placeholders are expanded from explicitly allowed machine-local values (such as `HOME`, `CMUX_AGENT_CONFIG`, and `CMUX_AGENT_RUNTIME`), never by evaluating arbitrary shell text. The supervisor performs this validation at launch as well. A missing required hook/event sink is a failure; it is never silently downgraded to screen polling.

Profile IDs are restricted to a simple identifier (`[A-Za-z0-9][A-Za-z0-9._-]*`). The loader reads exactly `<profile-id>.json` from the configured directory, parses one JSON object, verifies the schema version and required fields, and rejects path traversal, duplicate/unknown security settings, malformed arrays, and unexecutable commands. Cwd binding is always the contract cwd after `pwd -P`/`realpath` canonicalization. The normalized cwd is recorded in diagnostics so macOS `/tmp` → `/private/tmp` symlinks cannot create a false mismatch.

## Profile shape

The checked-in templates use this stable shape:

- `profile_id`, `schema_version` — identity and schema version.
- `launch.command`, `launch.argv`, `launch.mode` — trusted executable and argv; mode is `interactive` for this slice. `batch` requires a dedicated adapter and is not complete merely because it emits a structured event.
- `launch.permission_mode`, `launch.dangerous`, `launch.force`, `launch.yolo` — explicit permission/trust choice. No supervisor default turns on a dangerous mode.
- `cwd.binding`, `cwd.canonicalize` — contract cwd and canonicalization rule.
- `probes.ready`, `probes.idle`, `probes.question` — bounded cmux screen probes.
- `transport.prompt`, `transport.continuation` — explicit cmux send route; every command includes the recorded workspace and surface.
- `transcript.source`, `transcript.freshness`, `result.marker_rule` — fresh per-job output and nonce/prompt-echo boundary.
- `lifecycle.event`, `lifecycle.source`, `lifecycle.required`, `lifecycle.correlation`, `lifecycle.acceptable_statuses`, `lifecycle.failure_statuses` — lifecycle notification and correlation contract.
- `stop.mode`, `stop.deadline_seconds` — bounded stop behavior.

### Shell-safe launch assembly

The supervisor sends the setup and launch through a shell in the explicitly targeted cmux surface. A machine-local profile is trusted configuration, but its command, argv, and the requested cwd may contain spaces or shell metacharacters. The contract therefore requires that the supervisor shell-quote the contract cwd as one word and shell-quote `launch.command` plus every `launch.argv` element individually before assembling launch text. Use a shell-safe routine such as Bash `printf -- '%q' "$value"` (or the equivalent for the target shell), preserve empty argv values, and then join only the already-quoted words:

```bash
quote_shell_word() { printf -- '%q' "$1"; }
launch="cd -- $(quote_shell_word "$canonical_cwd") && exec $(quote_shell_word "$launch_command")"
for arg in "${launch_argv[@]}"; do
  launch+=" $(quote_shell_word "$arg")"
done
```

The same rule applies to the initialization `cd --` command. Never interpolate a raw cwd, command, or argv value, use unquoted concatenation, or pass assembled launch text through `eval`; shell quoting is required even for values read from a validated profile.

The common completion gate is unchanged for every profile:

1. A lifecycle event with an acceptable status and matching session/conversation/generation/workspace/job mapping wakes validation. `error`, `aborted`, missing, malformed, stale, and unknown events fail closed.
2. The fresh transcript/result source contains `<!-- CMX_JOB <job_nonce> -->` immediately before the expected marker. A marker in submitted input, prompt echo, reflected screen text, stale output, or an unrelated session is rejected.
3. Expected artifacts exist and requested `git diff --check`, focused tests, and other declared checks pass. An exit code or hook event alone is not enough.
4. The explicitly targeted cmux surface is alive and idle at the profile's follow-up probe. Screen output corroborates the result; it never replaces transcript/result evidence.
5. Repeated events are deduplicated by the profile's event/session/generation identity and must re-pass every check.

## Cursor interactive profile

`docs/examples/executor-profile.cursor.json` is a template for the first alternative executor. It intentionally launches the normal interactive Cursor CLI as:

```text
agent --trust
```

`--trust` is an explicit profile decision for the operator-approved disposable/project directory. It is not a blanket approval policy. Normal interactive mode can edit files without `--force`; tool/shell approvals still remain explicit decisions and must be routed or escalated by the supervisor. The template sets `dangerous`, `force`, and `yolo` to `false`; do not add `--force` or `--yolo` as a supervisor fallback.

The read-only readiness smoke probe used `agent --mode=ask --trust`; that mode is not the artifact-producing profile because Cursor documents Ask mode as read-only.

The profile's ready/idle/question probes are based on the observed Cursor interactive states. Prompt and continuation input are sent through the exact cmux workspace and surface recorded for this job. Before launch, the supervisor creates the per-job runtime directory and records the Cursor `transcript_path` plus the bounded PTY/result segment into the declared fresh source; it does not use a global unframed screen dump.

### Cursor stop hook

Cursor's supported user- or project-local `hooks.json` is the primary lifecycle notification source. The profile template uses the user location `${HOME}/.cursor/hooks.json` and the adapter `${HOME}/.cursor/hooks/cursor-stop-notify.sh`; the merged user registration must use the relative command `hooks/cursor-stop-notify.sh` because user hooks run from `${HOME}/.cursor`. For a project-local disposable check, place the merged file at the CLI's project hook location `.cursor/hooks.json`, copy the adapter to `.cursor/hooks/cursor-stop-notify.sh`, and use the project-relative command shown in `docs/examples/cursor-hooks.json`. The two command paths are intentionally different: Cursor resolves them relative to their hook location, and `${CMUX_AGENT_CONFIG}` is not a hook-command expansion. Merge the registration into the operator's existing `hooks.json` rather than overwriting it. Registration is an explicit machine-local setup step; the supervisor never writes the file or changes existing hooks. The adapter command includes a bounded five-second timeout in the template so a broken sink cannot hold a Cursor turn indefinitely.

The adapter should read the Cursor stop-event JSON and append one event per line to the configured machine-local sink. The observed event includes `hook_event_name: stop`, executor session identifiers, `status`, and `transcript_path`; the checked-in adapter preserves and validates those fields without granting approval or declaring success. Cursor does not provide the cmux surface or job nonce in the hook payload, so the supervisor records an active mapping before launch and correlates `conversation_id`, `generation_id`, `session_id`, and `transcript_path` to the active job, then binds that event to the job nonce, workspace, surface, and canonical cwd. Event identity must be stable enough to deduplicate reconnect/replay notifications. A hook status of `error` or `aborted`, a missing event, an unavailable sink, an uncorrelated session, or a malformed payload fails closed.

A `stop` event means that a Cursor turn ended. Cursor stop-hook notifications only wake validation; they are not proof of task correctness. It does **not** prove that the requested work or artifact succeeded. The supervisor still requires acceptable status, fresh correlated transcript/result evidence, nonce-framed marker excluding prompt echo, artifact/diff/focused checks, and idle cmux corroboration. Multiple stop events in a multi-turn job are expected and must not bypass the gate.

The repository does not include a real hook file or event sink. This keeps credentials, user paths, and machine-local hook state out of Git.

### Cursor batch and ACP follow-ups

The installed Cursor CLI also exposes `agent --print --output-format stream-json` and `agent acp`. They remain follow-ups, not default transports: a probe produced a structured assistant event but also reconnected/replayed assistant output. A dedicated adapter still needs terminal-result detection, replay/deduplication, approval routing, cwd binding, and artifact semantics. Do not report a batch assistant event as task completion.

## agy compatibility profile

`docs/examples/executor-profile.agy.json` moves the existing agy-specific launch and result details out of the common skill while retaining the old caller alias. On a machine that provides the existing local files, the profile uses:

- the explicit `~/bin/agy-with-permissions` wrapper (which expands to the intended dangerous-mode invocation);
- the existing `agy-result-hook` as a `PostInvocation` hook, not a `PreInvocation` hook;
- `~/agi-result.txt` as the result transcript source; and
- the same nonce-framed markers, explicit cmux surface routing, bounded timeout, artifact checks, and idle corroboration as every profile.

The wrapper and hook are not installed, copied, or modified by this repository. Their absence is a pre-launch failure, not permission to fall back to another CLI or screen-only evidence. The agy profile is compatibility support, not a second supervisor.

The current implementation machine has `cmux 0.64.22` and Cursor `agent 2026.08.11-e8db854`, but no `~/bin/agy-with-permissions`, `~/bin/agy-hook-notify.sh`, or `~/agi-result.txt`. Therefore agy live validation is **pending** until a machine with those wrapper/hook files performs the disposable probe.

## Disposable validation record

Use a disposable canonical Git directory and a fresh cmux pane/surface for live checks. Never use a destructive or spending task, and remove temporary panes, runtime transcripts, and directories after recording evidence.

Cursor validation covered by this slice:

- `cmux ping` responded `PONG` and Cursor reported `2026.08.11-e8db854`.
- The read-only readiness smoke probe used explicit `--mode=ask --trust` in a disposable checkout; a harmless prompt returned and the surface returned to its idle follow-up state.
- The normal interactive Cursor profile used explicit `--trust` for the harmless artifact probe and created exactly one disposable artifact; the checkout showed only that expected untracked file. No force/yolo mode was used.
- Cursor requested a one-time approval before running local content/diff checks; that explicit approval was sent through the recorded surface. No broad approval mode was enabled.
- A project-local disposable `stop` hook emitted JSON with `hook_event_name: stop`, session identifiers, status, and `transcript_path`. A separate stop probe also surfaced `WritableIterable is closed` with `status: error`, which confirms that hook events are notifications and must be fail-closed rather than accepted as success.
- A marker probe demonstrated prompt echo and an error status; screen text was therefore rejected as authoritative. Marker acceptance remains fresh transcript/result plus artifact/check plus idle corroboration.
- A `cmux events --category terminal` probe emitted only its subscription acknowledgment, so cmux terminal events are not treated as the primary Cursor transcript/result source.
- A second harmless job must use a new surface in the reused `cmux-agent` workspace. Timeout/stop, stale-marker, replay/deduplication, acceptable-status, and error-status cases are contract tests and bounded disposable checks; no screen-only completion is valid.

The repository's static contract and focused profile tests are the repeatable local gate:

```bash
bash tests/cmux-agent-orchestration-contract.sh
bash tests/executor-profile-contract.sh
git diff --check
```
