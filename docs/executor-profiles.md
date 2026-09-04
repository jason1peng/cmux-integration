# Machine-local executor profiles

CMX-003 makes the cmux supervisor independent of the CLI installed on a particular machine. The supervisor is the generic `.pi/agents/cmux-agent.md` agent. `agy` and `cmux-agent-supervisor` remain aliases for that one agent; they are not separate supervisors.

The profile is the only place that selects an executable, permission/trust mode, input transport, transcript/result source, lifecycle event, and stop behavior. Profiles and hook state are machine-local. Do not commit a real profile, a transcript, a credential, a socket/event queue, or a user hook to this repository.

## Selection and setup

Both executor options use the same five-step setup:

1. Create the machine-local profile/runtime directories.
2. Copy the selected profile template as `<profile-id>.json`.
3. Configure that executor's lifecycle hook and result source.
4. Export the profile-selection environment variables (or put `executor_profile` in the job contract).
5. Run a harmless disposable job and confirm lifecycle, transcript, artifact, and idle evidence.

The important difference is ownership: this repository includes both the Cursor adapter/template and the portable agy wrapper + lifecycle-hook templates, while the agy product itself (the executable, credentials, and working registration) must already be supplied by the machine’s agy installation. The agy templates are placed locally by the operator, never silently installed or modified here.

### 1. Common profile setup

Run this in the environment that starts Pi. Keep these values outside the repository:

```bash
repo=/path/to/cmux-integration
export CMUX_AGENT_CONFIG="$HOME/.config/cmux-agent"
export CMUX_AGENT_PROFILE_DIR="$CMUX_AGENT_CONFIG/profiles"
export CMUX_AGENT_RUNTIME="$HOME/.local/state/cmux-agent"
mkdir -p "$CMUX_AGENT_PROFILE_DIR" "$CMUX_AGENT_RUNTIME/jobs" "$CMUX_AGENT_RUNTIME/events"
```

Install one or both profile templates:

```bash
cp "$repo/docs/examples/executor-profile.cursor.json" \
   "$CMUX_AGENT_PROFILE_DIR/cursor.json"
cp "$repo/docs/examples/executor-profile.agy.json" \
   "$CMUX_AGENT_PROFILE_DIR/agy.json"
```

The supervisor resolves profiles in this order:

1. An explicit `executor_profile` in the `<CMUX_AGENT_JOB>` contract.
2. `CMUX_AGENT_EXECUTOR`, when the job omits `executor_profile`.
3. No fallback. Missing or unknown selection fails before the prompt is sent.

For example, select one executor for the current Pi session with:

```bash
export CMUX_AGENT_EXECUTOR=cursor   # or agy; this is an explicit choice
```

A job-level selector takes precedence over the environment:

```text
<CMUX_AGENT_JOB>
executor_profile: cursor
# For agy, replace the line above with: executor_profile: agy
...
</CMUX_AGENT_JOB>
```

The `agy`/`cmux-agent-supervisor` names are aliases for the generic supervisor; they do not select a CLI. There is no CLI auto-detection, and task text cannot supply a command, argv, executable path, or permission flag.

### 2. Configure the lifecycle source

Both profiles require a lifecycle notification/result source. A hook event only wakes validation; it never proves task correctness. For Cursor, the hook-provided transcript is authoritative content while hooks remain asynchronous observations. The shared completion gate still requires a fresh correlated assistant marker, expected artifacts/checks, no active question, and idle cmux corroboration.

| Profile | Launch | Lifecycle setup | Result source | Supplied by this repository |
| --- | --- | --- | --- | --- |
| `cursor` | `agent --trust` | Additive Cursor bridge hooks; `stop`/`afterAgentResponse` are optional wakeups | Hook-provided Cursor JSONL normalized per-job result plus correlated bridge events | Profile, bridge/watcher, adapters, and project/user hook templates |
| `agy` | `~/bin/agy-with-permissions` (portable template) | agy `PostInvocation` `agy-result-hook` against the portable `agy-hook-notify.sh` adapter plus the result file and runtime sink | `~/agi-result.txt` plus the agy lifecycle event | Templates provided; operator installs the wrapper/adapter and registers the hook locally |

A missing executable, hook, event sink, transcript source, or required registration is a pre-launch failure. Do not create dummy files or silently fall back to screen polling.

### Per-job timeline

Every job also writes metadata-only events to `$CMUX_AGENT_RUNTIME/jobs/<job_nonce>/cmux-agent.timeline.ndjson`. The bridge records correlated hook observations, the watcher records state transitions and observation-reason changes, and the supervisor records lifecycle, question, completion-gate, and surface-cleanup milestones with explicit supervisor provenance. Timeline records never contain prompts, transcript text, credentials, or command output.

After the final `job_finished` event, the supervisor renders a deterministic report for successful, failed, timed-out, and escalated jobs:

```bash
python3 tools/cmux-agent-timeline.py view \
  --timeline "$CMUX_AGENT_RUNTIME/jobs/<job_nonce>/cmux-agent.timeline.ndjson" \
  --format html > "$CMUX_AGENT_RUNTIME/jobs/<job_nonce>/cmux-agent.timeline.html"
```

The HTML graph is responsive, keeps event tooltips within its bounds, shows the watcher-detected state band, and reports observation milestones, prompt-to-first-normalized-record latency, state dwell, and question latency. Markdown and JSON views are also available, and the same timeline input produces byte-identical HTML. Timeline output is diagnostic only and never replaces fresh transcript/result, lifecycle, artifact/check, or idle evidence.

### 3. Cursor setup

The Cursor profile invokes a machine-local watcher at `${CMUX_AGENT_CONFIG}/bin/cursor-result-watcher.sh`. Install the reviewed disposable template explicitly before selecting the profile; the supervisor never creates or repairs this executable:

```bash
mkdir -p "$CMUX_AGENT_CONFIG/bin"
cp "$repo/docs/examples/cursor-result-watcher.sh" \
   "$CMUX_AGENT_CONFIG/bin/cursor-result-watcher.sh"
cp "$repo/tools/cmux-agent-command-policy.py" \
   "$CMUX_AGENT_CONFIG/bin/cmux-agent-command-policy.py"
chmod +x "$CMUX_AGENT_CONFIG/bin/cursor-result-watcher.sh" \
         "$CMUX_AGENT_CONFIG/bin/cmux-agent-command-policy.py"
```

Install the adapter in the supported user-hook location:

```bash
mkdir -p "$HOME/.cursor/hooks"
cp "$repo/docs/examples/cursor-stop-notify.sh" \
   "$HOME/.cursor/hooks/cursor-stop-notify.sh"
chmod +x "$HOME/.cursor/hooks/cursor-stop-notify.sh"
```

Merge this `stop` entry into the existing `$HOME/.cursor/hooks.json`; preserve unrelated hooks and do not overwrite the whole file:

```json
{
  "version": 1,
  "hooks": {
    "stop": [
      { "command": "hooks/cursor-stop-notify.sh", "timeout": 5 }
    ]
  }
}
```

The user-hook command is relative to `$HOME/.cursor`. For a disposable project instead, copy the adapter to `.cursor/hooks/cursor-stop-notify.sh` and merge `docs/examples/cursor-hooks.json` into that project's `.cursor/hooks.json`. The project command is intentionally `.cursor/hooks/cursor-stop-notify.sh`; do not use the user-relative command in a project hook, and do not use `${CMUX_AGENT_CONFIG}` as a Cursor hook command expansion.

### 4. agy setup

The agy profile is compatibility support for an existing agy installation. This repository now provides portable, reviewed templates for the wrapper and lifecycle hook that the machine-local agy setup requires; it still does not (and cannot) provide the agy product itself, your model credentials, or a working hook registration. Completing the setup below is an explicit machine-local operator step, not something the supervisor does for you.

#### a. Prerequisites

The supported product is the Antigravity-family `agy` CLI (the contract here was validated against `agy 1.1.13`), which registers named lifecycle hooks in the global config `~/.gemini/config/hooks.json` and delivers camelCase JSON payloads to hook commands on stdin. This is not the standard Gemini CLI hook model; do not substitute another CLI. agy must be installed and on `$PATH` so `agy --version` identifies the CLI, `python3` must be available for the lifecycle adapter and installer, and the machine must supply the agy product configuration (for example credentials and an identity). This repository does not install or configure agy, its model/credential store, or its identity. If agy is absent or unconfigured, do not select the `agy` profile; the supervisor fails closed rather than falling back to another CLI.

#### b. What this repository provides

- `docs/examples/agy-with-permissions.sh` — a portable launcher that starts agy as `agy --dangerously-skip-permissions` and forwards arguments. It contains no credentials, tokens, or private paths.
- `docs/examples/agy-hook-notify.sh` — a portable `PostInvocation` lifecycle adapter. It validates the camelCase agy hook JSON, requires the supervisor's persisted `agy.mapping.json`, binds `transcriptPath` to the configured canonical source, reads only complete records after the persisted source cursor, and stages result/event evidence in a durable pending transaction before committing the source cursor. Recovery is idempotent across crashes and persistence failures, so a replay cannot append normalized output or lifecycle evidence twice. It never approves tools, edits user files, or grants permission.
- `docs/examples/agy-result-hook.hooks.json` — a registration fragment that names the hook `agy-result-hook` and binds the installed adapter as its `PostInvocation` command.
- `docs/examples/agy-install.sh` — an explicit-confirmation installer that copies the wrapper and adapter into `~/bin` and merges the `agy-result-hook` fragment into the global agy hooks config without deleting unrelated hooks.
- `tests/agy-executor-contract.sh` — focused contract coverage for the wrapper, adapter, registration, installer, and no-secret/no-private-path bounds.

#### c. What must come from the local agy installation

- The agy executable itself and its product configuration (models, authentication, identity).
- The global hooks config (`~/.gemini/config/hooks.json`) into which the agy-result-hook registration is merged. The operator confirms this edit.
- The decision to launch agy in dangerous permission mode (only via the wrapper). This mode removes OS permission prompts within the approved workspace; it does **not** authorize content decisions.

#### d. Required environment variables

- `CMUX_AGENT_CONFIG` — base machine-local config root (`~/.config/cmux-agent`).
- `CMUX_AGENT_PROFILE_DIR` — directory containing `agy.json`, a copy of the agy profile template.
- `CMUX_AGENT_RUNTIME` — machine-local runtime directory (default `~/.local/state/cmux-agent`), writable by the Pi process. The lifecycle event sink is `$CMUX_AGENT_RUNTIME/events/agy-result.ndjson`.
- `CMUX_AGENT_JOB_RUNTIME` — supervisor-generated canonical runtime root exported to the agy hook; it contains `jobs/<job_nonce>/agy.mapping.json` and must match `CMUX_AGENT_RUNTIME`.
- `CMUX_AGENT_JOB_NONCE` — fresh supervisor-generated nonce selecting the active agy mapping.
- `CMUX_AGENT_HOOKS_CONFIG` (optional, installer only) — overrides the agy global hooks config path.
- `CMUX_AGENT_EXECUTOR` — must be `agy` explicitly, or the job must declare `executor_profile: agy`.

There is deliberately no result-file override environment variable: `${HOME}/agi-result.txt` is part of the contract, and the adapter and the profile's `transcript.source` must name the same file. Relocating the result file means editing both the installed adapter and the machine-local `agy.json` together; a mismatch fails validation rather than silently reading two different sources.

#### e. Profile setup

```sh
repo=/path/to/cmux-integration
export CMUX_AGENT_CONFIG="$HOME/.config/cmux-agent"
export CMUX_AGENT_PROFILE_DIR="$CMUX_AGENT_CONFIG/profiles"
export CMUX_AGENT_RUNTIME="$HOME/.local/state/cmux-agent"
mkdir -p "$CMUX_AGENT_PROFILE_DIR" "$CMUX_AGENT_RUNTIME/jobs" "$CMUX_AGENT_RUNTIME/events"
cp "$repo/docs/examples/executor-profile.agy.json" "$CMUX_AGENT_PROFILE_DIR/agy.json"
```

#### f. Wrapper setup

Review, then copy `docs/examples/agy-with-permissions.sh` to `~/bin/agy-with-permissions` (or run the installer). It must be executable by the Pi process. The wrapper is the only place the dangerous flag appears; the supervisor never adds one and never accepts a command or flags from task text.

#### g. PostInvocation hook registration

Review the portable adapter, then register it as the `PostInvocation` handler of the hook name `agy-result-hook` in the global agy hooks config. Merge, rather than overwrite, so unrelated hooks are preserved. The installer performs this merge only after explicit confirmation, and it resolves the registered command to the actually installed absolute adapter path (for example `${HOME}/bin/agy-hook-notify.sh`), so hook-runtime HOME expansion can never misresolve a staged install. The committed fragment keeps the `~/bin/agy-hook-notify.sh` form for operators merging by hand, which is correct only for a default install under the process HOME.

#### h. Lifecycle adapter setup

The adapter must be executable and able to write both the result file and the runtime event sink. Before launch, the supervisor persists `${CMUX_AGENT_JOB_RUNTIME}/jobs/${CMUX_AGENT_JOB_NONCE}/agy.mapping.json` with canonical source/result paths, file identity, byte offsets, and positive launch mtimes, then exports both job environment variables to agy. agy delivers one camelCase JSON object per `PostInvocation` on stdin; the adapter requires `transcriptPath`, `conversationId`, and an integer `invocationNum`, and exits non-zero without writing anything when a field is missing, malformed, unbound, stale, truncated, replaced, or unreadable.

For each accepted invocation identity it appends at most one event line to `$CMUX_AGENT_RUNTIME/events/agy-result.ndjson`; an identical replay is recognized without another append:

```json
{"hook_event_name":"PostInvocation","hook":"agy-result-hook","job_nonce":"<jobNonce>","event_id":"<jobNonce>:<conversationId>:<invocationNum>:<transcriptSize>","executor_session":"<conversationId>","conversation_id":"<conversationId>","invocation_num":3,"transcript_path":"...","transcript_size":4567,"transcript_offset":1234,"source_offset":4567,"source_start_offset":4000,"status":"success"}
```

Correlation is split by ownership. The hook supplies invocation identity and observed cursors: `executor_session`, `conversation_id`, `invocation_num`, `transcript_size`, canonical `transcript_path`, `source_offset`, `source_start_offset`, and `transcript_offset` (the result-file byte offset where this invocation's normalized segment starts). The adapter binds the supervisor-owned `job_nonce` from the environment into `event_id` and the event envelope; the supervisor owns that nonce plus `workspace`, `surface`, and `cwd` through `agy.mapping.json` recorded before launch. The adapter accepts a hook path only when its canonical value equals the mapping's configured source path; it never lets the payload replace supervisor-owned source/result identity.

`event_id` is `<jobNonce>:<conversationId>:<invocationNum>:<transcriptSize>`. agy resets `invocationNum` to 0 for every user turn (observed on agy 1.1.19), so conversation plus invocation alone would collide across turns of one session; the transcript byte size at delivery is agy-owned, grows monotonically per turn, and is unaffected by this adapter, which makes the four-part identity stable when the same notification is replayed yet distinct for each real turn and job. Deduplication uses the profile's `deduplicate_by` identity — `event_id` plus `executor_session` — so a replayed notification re-presents the same declared identity and is deduplicated rather than double-counted. `transcript_offset` and `source_offset` are deliberately **not** part of the dedupe identity: they are cursor metadata, while a replay of the same source size and invocation must retain the same event identity and produce no new normalized bytes.

`status: success` means only that this `PostInvocation` callback ran and captured fresh transcript data. The agy `PostInvocation` payload carries no status or error field, so the adapter synthesizes this value and documents it here rather than inventing richer semantics. It never proves task correctness: completion still requires the correlated nonce-framed marker in the fresh segment, artifact/diff/focused checks, and idle cmux corroboration, all of which fail closed independently.

#### i. Result-file setup

The result file `${HOME}/agi-result.txt` is the normalized transcript source the profile reads, and its path is part of the contract: the installed adapter, mapping `result.path`, and machine-local profile `transcript.source` must name the same canonical file. There is no override environment variable; relocating the file means editing all three together, and a mismatch fails validation instead of silently reading two sources. The hook creates the result file on its first append; it is never an empty placeholder installed in advance. Before launch the supervisor records separate source and result identities, byte offsets, and mtimes in `agy.mapping.json`; the adapter reads only source bytes after the persisted source boundary and stages only that normalized fresh segment. It commits the cursor only after the result and lifecycle event are durable; a pending transaction repairs an interrupted append or recognizes already-written evidence before retrying.

#### j. Harmless validation

Run the repository contract checks, then run a disposable canonical Git checkout in a new `cmux-agent` surface and ask for exactly one harmless artifact. See “Disposable validation record”.

#### k. Troubleshooting

- **“agy profile unavailable”**: verify `agy.json` exists in `$CMUX_AGENT_PROFILE_DIR`, `agy` is on `$PATH`, and `CMUX_AGENT_EXECUTOR=agy` (or `executor_profile: agy`) is set for the job.
- **Hook never fires / no result file**: verify the agy-result-hook PostInvocation registration points at the correct adapter, and `CMUX_AGENT_RUNTIME` is defined and writable.
- **Lifecycle event missing or uncorrelated**: confirm `$CMUX_AGENT_RUNTIME/events/agy-result.ndjson` was written and the job’s transcript/conversation mapping is fresh.
- **Marker appears but the job is not accepted**: screen text or prompt echo is not authoritative; inspect the fresh result segment, lifecycle correlation, artifact/diff/focused checks, and the idle surface.
- **Missing agy**: do not unset or substitute. Resolve the agy product/credential setup, or leave agy unselected.

#### l. Security/dangerous-mode behavior

The wrapper starts agy with `--dangerously-skip-permissions`. That removes OS permission prompts inside the approved workspace; it does not approve content or widen scope. The pipeline stays fail-closed: `NEED_APPROVAL` holds the executor tool-free until the main agent decides, `QUESTION` is relayed verbatim, and `error`, `aborted`, stale, replayed, malformed, or missing events close the job. The supervisor never adds `--force` or `--yolo`.

#### m. Known limitations

- Only interactive agy is supported here; agy batch/ACP adapters remain future work.
- The wrapper and hook are compatibility support: they depend on an installed, configured agy product. If agy is absent, leave it unselected and use cursor instead.
- Hook registration and result-file placement remain explicit operator steps; none of this is implicit or auto-repaired.

### 5. Switch or verify the selected profile

Switching between executors only changes the explicit selector; the common cmux routing, approval, marker, timeout, and completion rules remain the same:

```bash
export CMUX_AGENT_EXECUTOR=cursor
# or:
export CMUX_AGENT_EXECUTOR=agy
```

Before relying on either profile, validate the selected executable and lifecycle source, then run the harmless disposable checks documented below. Profile placeholders are expanded only from explicitly allowed machine-local values such as `HOME`, `CMUX_AGENT_CONFIG`, and `CMUX_AGENT_RUNTIME`; arbitrary shell text is never evaluated. The supervisor repeats profile, cwd, executable, hook, and sink validation at launch.

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
- `supervisor_mapping` — required supervisor-owned mapping and exports for source/result identity, launch boundaries, and job binding.
- `lifecycle.event`, `lifecycle.source`, `lifecycle.required`, `lifecycle.correlation`, `lifecycle.acceptable_statuses`, `lifecycle.failure_statuses` — lifecycle notification and correlation contract.
- `capability_policy_version`, `capability_adapter` — versioned capability negotiation metadata. Profiles that lack the supported version or required adapter fail closed before launch; the adapter declares local/cached discovery, readiness digest checks, request transport, and the `capability-protocol-version-skew` reason.
- `stop.mode`, `stop.deadline_seconds` — bounded stop behavior.

The common skill owns the CLI-neutral `capability_manifest`, canonical task core, `task_payload_sha256`, route modes (`direct_pi`, `supervised_cli_refresh`, and `manual_handoff`), `CMX_CAPABILITY_READY`/request/decision envelopes, bounded request and reminder recovery, and labeled evidence. Profile adapters only transport these records and supply CLI-specific discovery/transcript/lifecycle details; they may not rewrite the task core or grant authority.

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

`docs/examples/executor-profile.cursor.json` is the supported Cursor template. It intentionally launches the original non-headless interactive CLI as:

```text
agent --trust
```

`--trust` is an explicit profile decision for the operator-approved disposable/project directory. It is not blanket content approval. Normal interactive mode can edit files without `--force`; tool/shell approvals remain explicit decisions and must be routed or escalated. The template sets `dangerous`, `force`, and `yolo` to `false`; the supervisor never adds those flags. Cursor batch (`--print --output-format stream-json`) and ACP remain deferred.

The profile's ready/idle/question probes are bounded screen corroboration. Prompt and continuation input are sent through the exact recorded cmux workspace/surface, and `ctrl+enter` is the verified TUI submit action. Before launch, the supervisor writes a fresh `cursor.mapping.json` containing the job nonce, canonical cwd, workspace, surface, prompt, source identity, and source boundary. It exports the per-job runtime on `CMUX_AGENT_JOB_RUNTIME` in addition to the common supervisor mapping. Hook payloads and pane text cannot replace those fields.

### Hook-provided transcript bridge

`docs/examples/cursor-transcript-bridge.sh` is an additive command-hook adapter. Register it for `sessionStart`, `beforeSubmitPrompt`, `afterAgentThought`, `afterFileEdit`, `afterShellExecution`, and optionally `afterAgentResponse`; register it alongside the existing stop adapter. Hooks are notifications only: they are asynchronous wakeups and identity/path observations. The bridge accepts the first usable non-null `transcript_path` from a correlated hook payload, or the supplied `CURSOR_TRANSCRIPT_PATH` fallback, only when its canonical absolute value exactly matches the supervisor mapping's required `source.path`. Null/future paths remain observations until a later hook supplies that mapped source. The bridge never scans undocumented Cursor directories.

The bridge reads only the hook-provided JSONL source after the supervisor boundary. It requires canonical `source.path`, source start offset, launch mtime, existence/creation identity, and path/device/inode/size/mtime checks; it rejects malformed JSONL, stale or uncorrelated sessions, source truncation, replacement, and in-place prefix changes. It normalizes only fresh assistant/tool records, preserves source offsets, excludes user records, removes exact or line-segment prompt echoes without dropping nearby legitimate assistant text, and deduplicates semantic replay. Result/event bytes and the next source cursor are coordinated through a durable pending transaction: evidence is applied idempotently, then the cursor is atomically committed, and a retry repairs or recognizes any interrupted step without duplicate completion evidence. When a transcript record supplies session, conversation, generation, cwd, workspace, or surface identity, every value must match the hook identity and supervisor mapping; foreign records are rejected before filtering. A `stop`/hook `error` or `aborted` status is latched in the per-job bridge state, and all later callbacks remain failed closed even if they report success. Its per-job result at `${CMUX_AGENT_RUNTIME}/jobs/${job_nonce}/cursor.pty-result.ndjson` is the authoritative content source. The bridge event sink is a wakeup/identity source, not a completion proof. Inside Cursor hook processes, the supervisor passes the per-job runtime as `CMUX_AGENT_JOB_RUNTIME`; Cursor reserves/overwrites the common `CMUX_AGENT_RUNTIME` name.

### Optional Cursor stop hook and response wakeups

The stop adapter writes `${CMUX_AGENT_RUNTIME}/events/cursor-stop.ndjson` and returns `{}` so Cursor command-hook execution remains valid. `stop` and `afterAgentResponse` are optional wakeups: an accepted stop status can trigger validation, `error` or `aborted` fails closed, and missing stop never downgrades transcript validation. The existing Agoda monitoring hook is preserved; registration is an explicit operator action, and this repository never writes user hooks, credentials, profiles, transcripts, or runtime state.

### Turn-settled completion gate and watcher

The supervisor accepts a Cursor job only when a fresh correlated normalized assistant record contains the current nonce-framed marker, expected artifacts/checks pass, no approval/question is active, and the explicitly targeted surface is alive at the normal follow-up/idle prompt. A marker in submitted input, user/prompt echo, stale/replayed data, or screen text is rejected. The deterministic local `cursor-result-watcher.sh` polls bridge result/event activity at bounded intervals using `stat` identity checks and persisted byte cursors, reads only bounded appended NDJSON chunks, and emits `WORKING` on fresh activity. After five quiet seconds it reads the exact surface and emits `REQUIRE_ATTENTION` with bounded pane evidence; quiet is ambiguous, so the LLM/supervisor decides what to do. While quiet persists, pane reads are throttled to at most once per second. It may then emit `QUESTION`, `IDLE`, `LOST`, or `UNKNOWN` as pane corroboration changes. Working indicators outrank generic follow-up text. The watcher never approves, answers, retries, or supplies result content.

#### Optional quiet-period advisor and safe-command policy

The Cursor profile advertises an optional bounded local LLM advisor command at `${CMUX_AGENT_CONFIG}/bin/cursor-advisor.sh`. When it is enabled, also install the authoritative non-executing command policy at `${CMUX_AGENT_CONFIG}/bin/cmux-agent-command-policy.py`; the watcher/advisor fail closed if that validator is unavailable. Install the reviewed disposable reference adapter when this bounded recommendation channel is desired; it is deterministic by default and can be replaced by a local LLM adapter that preserves the strict response schema:

```bash
mkdir -p "$CMUX_AGENT_CONFIG/bin"
cp "$repo/docs/examples/cursor-advisor.sh" \
   "$CMUX_AGENT_CONFIG/bin/cursor-advisor.sh"
chmod +x "$CMUX_AGENT_CONFIG/bin/cursor-advisor.sh"
```

The watcher invokes the configured advisor only after **15 seconds of quiet** following the latest correlated transcript/bridge-event activity and passes the current watcher state (normally `REQUIRE_ATTENTION`), bounded transcript evidence, exact-pane evidence, canonical cwd, and declared scope. Calls use a persisted **15/30/60-second backoff capped at 60 seconds**; any fresh result or bridge-event activity resets the attempt counter and next due time. The advisor returns exactly one strict JSON recommendation using policy `routine-command-v2`; the copyable adapter delegates command parsing to the authoritative `tools/cmux-agent-command-policy.py` validator and never carries an independent allowlist. A recommendation is never an approval: the supervisor/LLM owns the decision and sends any response through the explicit cmux surface. If the policy adapter is unavailable or returns malformed output, the supervisor fails closed.

Only an exact displayed command from the question may be recommended as `decision: approve`. The advisor and watcher delegate command validation to the single authoritative `tools/cmux-agent-command-policy.py` `routine-command-v2` adapter, using the supervisor's canonical cwd and declared scope; they do not carry an independent allowlist. For Git reads, that validator also performs a bounded non-executing configuration preflight and escalates active external-diff, fsmonitor, pager, textconv/filter, hooks, repository-redirect, or helper-environment settings; it never invokes Git or a configured helper while checking. Explicit `--no-ext-diff`, `--no-textconv`, and `--no-pager` disable only their matching helper class. Shell operators, substitution, chaining, malformed quoting, unknown commands, out-of-scope paths, network/write/topology operations, and command text that is not exact are not routine. Mandatory escalation categories are `destructive`, `credential`, `deployment`, `external-network`, `ambiguous`, and `important` (including trust/authorization, authentication, spending, irreversible, or scope-expanding decisions). The watcher overrides an unsafe advisor approval into escalation. An unavailable, timed-out, malformed, or otherwise invalid policy/advisor response fails closed and escalates; an unconfigured optional advisor is simply disabled.

For hook setup, copy the bridge and stop adapters to the selected user or disposable project hook directory and merge the relevant entries from `docs/examples/cursor-hooks.json` without replacing unrelated hooks. User commands are relative to `${HOME}/.cursor`; project commands are relative to `.cursor`. The project-relative command is `.cursor/hooks/cursor-transcript-bridge.sh`; do not substitute `${CMUX_AGENT_CONFIG}` for either path. The hook template uses a bounded five-second timeout.

## agy compatibility profile

`docs/examples/executor-profile.agy.json` moves the existing agy-specific launch and result details out of the common skill while retaining the old caller alias. On a machine that provides the existing local files, the profile uses:

- the explicit `~/bin/agy-with-permissions` wrapper (which expands to the intended dangerous-mode invocation);
- the existing `agy-result-hook` as a `PostInvocation` hook, not a `PreInvocation` hook;
- `~/agi-result.txt` as the result transcript source; and
- the same nonce-framed markers, explicit cmux surface routing, bounded timeout, artifact checks, and idle corroboration as every profile.

The wrapper and adapter templates are provided in `docs/examples/` and placed locally by the operator; this repository does not silently modify user hooks. A missing wrapper or adapter remains a pre-launch failure, not permission to fall back to another CLI or to screen-only evidence. The agy profile is compatibility support, not a second supervisor.

The machine represented by this record has `cmux`, Cursor `agent`, and agy with the wrapper, adapter, result source, and `PostInvocation` registration. Live agy validation evidence is recorded below; on any other machine without an installed agy wrapper or adapter, agy remains unselected and the profile fails closed.

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

### CMX-004 interactive live-validation record

The following disposable run records the complete interactive consumer path; it is evidence, not machine-local configuration to copy:

- **Launch and routing:** Cursor `2026.08.11-e8db854` was launched as `agent --trust` in a fresh `cmux-agent` surface (`workspace:41`, `surface:185`) with a fresh nonce `cmx004-live-fixed-65d37c7e034bc6a34331`; prompt submission used the verified `ctrl+enter` TUI action. `cmux ping` returned `PONG`.
- **Hook observations and path:** project-local additive hooks observed `sessionStart`, `beforeSubmitPrompt`, multiple `afterAgentThought`, and `afterFileEdit`; path-bearing callbacks supplied the canonical Cursor `transcript_path`. The bridge captured that first usable hook-provided source (device `16777230`, inode `64247673`, final size `1368` bytes) without scanning undocumented directories.
- **Normalized result:** the bridge wrote the authoritative per-job `${CMUX_AGENT_RUNTIME}/jobs/<job_nonce>/cursor.pty-result.ndjson` with three correlated assistant records; user/prompt echo was absent. The nonce-framed marker was preserved in assistant content, immediately as `<!-- CMX_JOB cmx004-live-fixed-65d37c7e034bc6a34331 -->` followed by `<!-- GOAL_COMPLETE -->`.
- **Artifact and checks:** the disposable checkout contained exactly `cmx004-live-proof.txt` with bytes `CMX004_INTERACTIVE_LIVE_OK\n` (SHA-256 `7a90b2b40c3e64eba656ee092e7371a899556a4d44518ce1579cd846913f570c`); `git diff --check` passed.
- **Watcher and idle corroboration:** watcher transitions were `UNKNOWN → WORKING → IDLE → WORKING → IDLE → WORKING → IDLE`; the final `IDLE` was emitted after a bounded read of the exact mapped cmux surface with reason `pane-idle`, and workspace/surface/cwd correlation matched the supervisor mapping. No `stop` event was required for the settled gate.
- **Cleanup and hook preservation:** the disposable surface, checkout, runtime files, hook logs, and Cursor project metadata were removed after evidence capture. The existing user hook file was not modified (byte-for-byte SHA-256 `dac733b9b0e62d175e85858fade1cfb0e667ffe71667aae14cc9efef1da0f437`).

Agy adapter-wiring evidence from the portable templates (this iteration):

- The `agy-hook-notify.sh` lifecycle adapter is exercised against a disposable repo and transcript in `tests/agy-executor-contract.sh`: it reads the camelCase agy `PostInvocation` hook JSON from stdin, requires the supervisor mapping, ignores pre-launch source bytes, binds the supplied path to the configured canonical source, appends only fresh complete model records to the result file, and writes at most one correlated event line (`hook_event_name: PostInvocation`, `job_nonce`, `conversation_id`, `transcript_path`, `status: success`) for an invocation identity to the configured runtime sink. Crash-injection cases recover the durable pending transaction without duplicate result/event evidence. The test runs only under a temporary home/payload and never touches real hooks, profiles, transcripts, or the result file.
- Malformed, empty, non-object, and transcript-less payloads fail closed without an event or a fresh result segment.
- The `agy-with-permissions.sh` wrapper is asserted to launch exactly `agy --dangerously-skip-permissions "$@"` and forwards arguments; it adds no `--force` or `--yolo`.
- The installer merges the `agy-result-hook` registration into a disposable hooks config while preserving unrelated hook entries.
- Live wrapper-to-cmux wiring was probed additively in a fresh `cmux-agent` surface: launching the installed wrapper entered the agy product and surfaced the workspace-trust authorization prompt. Per the fail-closed policy the supervisor does not approve such a prompt; cancelling exited cleanly with no trust granted, no artifact created, no model call, and an empty runtime event sink.

**Remaining limitation for agy.** Loading an interactive agy agent consumes the stored agy credentials and a real model call, so this environment treats a fresh interactive run as a credentialed/spending act for an automated PR and does not launch it unprompted. The disposable case evidence already in this workspace (`cmx-agent` at the `cmux-test` checkout, where a harmless one-artifact task created `hello.html` and the result stream recorded a fresh segment ending `<!-- CMX_JOB <nonce> -->` immediately before `<!-- GOAL_COMPLETE -->`) is supporting evidence for the adapter wiring above. A fresh interactive agy probe remains an explicit operator step that must run on a disposable checkout and be cleaned up locally.

The repository's static contract and focused profile tests are the repeatable local gate:

```bash
bash tests/cmux-agent-orchestration-contract.sh
bash tests/executor-profile-contract.sh
bash tests/agy-executor-contract.sh
bash tests/cursor-transcript-bridge-contract.sh
bash -n tests/*.sh docs/examples/*.sh
python3 -m json.tool <each changed JSON file>
git diff --check
```
