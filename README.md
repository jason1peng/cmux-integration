# cmux executor profiles

This repository adds a profile-driven supervisor for running one interactive coding agent in a dedicated [cmux](https://github.com/manaflow-ai/cmux) pane.

It lets a Pi project use either:

- **Cursor `agent`** as the first supported alternative; or
- **agy** through the existing machine-local agy wrapper and hook setup.

The supervisor is the generic Pi agent at [`.pi/agents/cmux-agent.md`](.pi/agents/cmux-agent.md). Its compatibility aliases are `agy` and `cmux-agent-supervisor`.

> **Important:** the alias does not choose the CLI. The explicit executor profile chooses the CLI.

## How it works

```text
main Pi agent
    │  <CMUX_AGENT_JOB> + explicit profile
    ▼
generic cmux-agent supervisor
    │  resolves ~/.config/cmux-agent/profiles/<id>.json
    ▼
new cmux-agent pane/surface
    │  launches the selected interactive CLI
    ├── additive Cursor hook wakeups/path observation
    ├── hook-provided fresh JSONL transcript bridge
    ├── low-latency watcher + bounded pane fallback
    └── artifact/check + turn-settled idle corroboration
```

A hook event is only a wake-up signal and identity/path observation. The supervisor reports success only when all of these agree:

1. the lifecycle event is fresh, correlated, and has an acceptable status;
2. the fresh hook-provided transcript/result contains a nonce-framed assistant completion marker, not user/prompt echo;
3. expected artifacts and declared checks pass;
4. no approval/question is active; and
5. the explicit cmux surface is alive at the normal follow-up/idle prompt.

Screen output alone, an exit code alone, or a hook event alone never proves completion.

## What this repository does not do

- It does not auto-detect whether Cursor or agy is installed.
- It does not install or modify user hooks, credentials, profiles, or transcripts.
- It does not silently add `--force` or `--yolo`.
- It does not provide the agy wrapper or agy-specific hook files.
- Cursor batch (`--print --output-format stream-json`) and ACP remain deferred; interactive Cursor is the supported Cursor transport in this slice.

## Installation map

This repository is **not a Pi extension or an npm package**. It is a small Pi integration made of a project/user subagent, a custom skill, and machine-local executor templates. There is no `pi install` command for this repository.

Choose one of these scopes:

- **Global (recommended):** install the Pi resources under `~/.pi/agent/` and the executor templates under their `~/.config`, `~/.cursor`, or agy locations. The supervisor is then available from any project.
- **Project-local:** run Pi with this repository as the project context. The project agent and its skill are available only for this repository, while executor profiles and hooks are still machine-local.

### Core files (required for every executor)

| Purpose | Repository source | Global destination | Required? |
| --- | --- | --- | --- |
| Pi supervisor agent and aliases (`cmux-agent`, `agy`, `cmux-agent-supervisor`) | `.pi/agents/cmux-agent.md` | `~/.pi/agent/agents/cmux-agent.md` | Yes |
| CMX orchestration skill | `skills/cmux-agent-orchestration/SKILL.md` | `~/.pi/agent/skills/cmux-agent-orchestration/SKILL.md` | Yes |
| cmux pane skills | **Not supplied by this repository** | Existing global `cmux` and `cmux-workspace` skills | Yes |
| Profile/runtime directories | — | `~/.config/cmux-agent/` and `~/.local/state/cmux-agent/` | Yes |

When copying the project agent to the global agent directory, change its relative `skillPath` from `../../skills` to `../skills` (or rely on normal global skill discovery after installing the skill above). Do not copy a personal profile, credential, transcript, socket, or runtime state into Git.

### Cursor files

| Purpose | Repository source | Global destination | Required? |
| --- | --- | --- | --- |
| Cursor executor profile | `docs/examples/executor-profile.cursor.json` | `~/.config/cmux-agent/profiles/cursor.json` | Yes |
| Deterministic result watcher | `docs/examples/cursor-result-watcher.sh` | `~/.config/cmux-agent/bin/cursor-result-watcher.sh` | Yes |
| Transcript bridge hook | `docs/examples/cursor-transcript-bridge.sh` | `~/.cursor/hooks/cursor-transcript-bridge.sh` | Yes |
| Stop notification hook | `docs/examples/cursor-stop-notify.sh` | `~/.cursor/hooks/cursor-stop-notify.sh` | Optional wakeup |
| Cursor hook registration | `docs/examples/cursor-hooks.json` | Merge into `~/.cursor/hooks.json` | Yes for bridge |
| Bounded advisor | `docs/examples/cursor-advisor.sh` | `~/.config/cmux-agent/bin/cursor-advisor.sh` | Optional |

The hook registration must be merged additively; preserve existing monitoring hooks and unrelated entries. The supervisor never installs or overwrites user hooks silently.

### agy files

| Purpose | Repository source | Global destination | Required? |
| --- | --- | --- | --- |
| agy executor profile | `docs/examples/executor-profile.agy.json` | `~/.config/cmux-agent/profiles/agy.json` | Yes for agy |
| agy wrapper | `docs/examples/agy-with-permissions.sh` | `~/bin/agy-with-permissions` | Yes for agy |
| agy lifecycle adapter | `docs/examples/agy-hook-notify.sh` | `~/bin/agy-hook-notify.sh` | Yes for agy |
| agy lifecycle registration | `docs/examples/agy-result-hook.hooks.json` | Merge into the global agy hooks config | Yes for agy |
| agy result source | — | `~/agi-result.txt` | Yes for agy |

The agy CLI, credentials, and product configuration are external prerequisites. `agy-install.sh` performs the wrapper/adapter installation and hook merge with explicit confirmation.

### Global Pi resource installation

Run this once from a checkout of this repository. Inspect existing targets before replacing them; preserve local changes:

```bash
repo=/path/to/cmux-integration
mkdir -p "$HOME/.pi/agent/agents" \
         "$HOME/.pi/agent/skills/cmux-agent-orchestration"
cp "$repo/skills/cmux-agent-orchestration/SKILL.md" \
   "$HOME/.pi/agent/skills/cmux-agent-orchestration/SKILL.md"
sed 's|^skillPath: \.\./\.\./skills$|skillPath: ../skills|' \
  "$repo/.pi/agents/cmux-agent.md" > "$HOME/.pi/agent/agents/cmux-agent.md"
```

Then follow [Configure Cursor](#configure-cursor) and/or [Configure agy](#configure-agy) below. Set `CMUX_AGENT_CONFIG`, `CMUX_AGENT_PROFILE_DIR`, `CMUX_AGENT_RUNTIME`, and (unless selecting per job) `CMUX_AGENT_EXECUTOR` in the environment that starts Pi. Restart Pi after installing global agent/skill files.

### AI-assisted installation request

This is a safe, repeatable prompt for updating another machine or refreshing a merged checkout:

```text
Read <repo>/README.md, especially "Installation map", "Global Pi resource installation", "Configure Cursor", and "Configure agy". Install or update this cmux integration globally, not in the current project. First inspect every existing target and show the planned changes. Preserve unrelated Pi agents, Cursor hooks, agy hooks, credentials, profiles, and runtime state; merge hook entries additively; ask before changing user configuration. Install only the selected executor's required files, then run the documented verification commands and report missing prerequisites or skipped checks. Do not commit machine-local files.
```

## Prerequisites

### Required for every profile

- Pi with either this repository as the project context or the global Pi resources installed above.
- The separately installed `cmux` and `cmux-workspace` skills, available to the supervisor.
- `cmux` installed and usable (`cmux ping` should return `PONG`).
- A disposable or approved working directory for the executor job.
- A writable machine-local runtime directory.
- `python3` for the checked-in hook adapters: the Cursor stop adapter and the agy lifecycle adapter and installer all require it.

### Additional Cursor requirements

- Cursor's interactive `agent` CLI installed (`agent --version`).
- Permission to use the explicit `agent --trust` profile for the selected project directory.
- An additive Cursor hook registration for the bridge and optional stop wakeup. Hook registration remains an explicit machine-local setup step; this repository never edits it for you.
- Cursor's hook-provided `transcript_path`/`CURSOR_TRANSCRIPT_PATH` must be readable by the hook process. The supervisor exports the per-job runtime as `CMUX_AGENT_JOB_RUNTIME` because Cursor overwrites the common `CMUX_AGENT_RUNTIME` inside hook processes. The bridge fails closed rather than scanning undocumented transcript directories.

### Additional agy requirements

agy support is compatibility support for an existing agy installation. This repository provides portable, reviewed templates for the wrapper and lifecycle hook that the machine-local agy setup requires. The operator installs them locally; the agy product itself must already be installed and configured on the machine:

- `~/bin/agy-with-permissions` — executable agy launch wrapper (template: `docs/examples/agy-with-permissions.sh`);
- `~/bin/agy-hook-notify.sh` — executable `PostInvocation` lifecycle adapter (template: `docs/examples/agy-hook-notify.sh`);
- a `PostInvocation` hook named `agy-result-hook` registered in the global agy hooks config (fragment: `docs/examples/agy-result-hook.hooks.json`); and
- `~/agi-result.txt` — the agy result/transcript source. The path is part of the profile contract (the adapter and the profile must agree); it is not an environment override.

The templates are placed locally by the operator (or by `agy-install.sh` with explicit confirmation); this repository never silently creates, copies, or modifies user hooks. Product-specific items (the agy CLI, credentials, and working hook registration) remain the local agy installation. If any agy prerequisite is absent, leave agy unselected and use Cursor; the supervisor fails closed rather than falling back to screen polling.

## Setup shared by both profiles

Run these commands in the environment that starts Pi. Replace `/path/to/cmux-integration` with this checkout:

```bash
repo=/path/to/cmux-integration

export CMUX_AGENT_CONFIG="$HOME/.config/cmux-agent"
export CMUX_AGENT_PROFILE_DIR="$CMUX_AGENT_CONFIG/profiles"
export CMUX_AGENT_RUNTIME="$HOME/.local/state/cmux-agent"

mkdir -p "$CMUX_AGENT_PROFILE_DIR" \
         "$CMUX_AGENT_RUNTIME/jobs" \
         "$CMUX_AGENT_RUNTIME/events"

# Install one or both machine-local profile templates.
cp "$repo/docs/examples/executor-profile.cursor.json" \
   "$CMUX_AGENT_PROFILE_DIR/cursor.json"
cp "$repo/docs/examples/executor-profile.agy.json" \
   "$CMUX_AGENT_PROFILE_DIR/agy.json"
```

Do not commit the resulting files or runtime state. The profile loader accepts only the selected profile ID and validates the executable, cwd, hook/event source, and permission settings before launch.

## Configure Cursor

The selected transport is the normal interactive `agent --trust` CLI in a fresh explicitly routed cmux surface. The bridge is additive: it observes hook events, captures the first usable hook-provided transcript path, and writes the normalized per-job result. The supervisor exports `CMUX_AGENT_JOB_RUNTIME` for hook state; do not rely on `CMUX_AGENT_RUNTIME` inside Cursor hooks because Cursor reserves that name. It never approves tools, changes files, scans undocumented Cursor directories, or decides completion.

### 1. Install the disposable templates locally

The profile points at a machine-local watcher path. Install that reviewed, disposable template explicitly; the supervisor never copies it or repairs a missing installation:

```bash
mkdir -p "$CMUX_AGENT_CONFIG/bin"
cp "$repo/docs/examples/cursor-result-watcher.sh" \
   "$CMUX_AGENT_CONFIG/bin/cursor-result-watcher.sh"
chmod +x "$CMUX_AGENT_CONFIG/bin/cursor-result-watcher.sh"
```

The watcher is the deterministic polling component: it compares bounded
result/event cursors, treats fresh correlated activity as `WORKING`, and emits
`REQUIRE_ATTENTION` after five quiet seconds with exact-pane evidence. Quiet
is ambiguous; it is not completion and the LLM/supervisor decides what to do.
While quiet persists, pane reads are throttled to at most once per second.
`IDLE` remains only corroboration for the turn-settled gate.

The optional bounded local LLM advisor is a separate machine-local adapter.
Install only when routine read-only command questions should be classified:

```bash
cp "$repo/docs/examples/cursor-advisor.sh" \
   "$CMUX_AGENT_CONFIG/bin/cursor-advisor.sh"
chmod +x "$CMUX_AGENT_CONFIG/bin/cursor-advisor.sh"
```

It is invoked after 15 seconds of quiet with 15/30/60-second capped backoff;
new transcript/event activity resets that backoff. It receives the current
watcher state, bounded transcript evidence, and exact-pane evidence. Only an
exact displayed read-only local command is eligible. Destructive, credential,
deployment, external-network, ambiguous, important, trust/authorization,
authentication, spending, irreversible, and scope-expanding questions
escalate, and advisor failure is fail-closed. The advisor returns a
recommendation only; the supervisor/LLM owns and routes any response.

For user hooks, copy both adapters to the supported user location and review them:

```bash
mkdir -p "$HOME/.cursor/hooks"
cp "$repo/docs/examples/cursor-stop-notify.sh" \
   "$HOME/.cursor/hooks/cursor-stop-notify.sh"
cp "$repo/docs/examples/cursor-transcript-bridge.sh" \
   "$HOME/.cursor/hooks/cursor-transcript-bridge.sh"
chmod +x "$HOME/.cursor/hooks/cursor-stop-notify.sh" \
         "$HOME/.cursor/hooks/cursor-transcript-bridge.sh"
```

For a disposable project-local setup instead:

```bash
mkdir -p .cursor/hooks
cp "$repo/docs/examples/cursor-stop-notify.sh" \
   .cursor/hooks/cursor-stop-notify.sh
cp "$repo/docs/examples/cursor-transcript-bridge.sh" \
   .cursor/hooks/cursor-transcript-bridge.sh
chmod +x .cursor/hooks/cursor-stop-notify.sh \
         .cursor/hooks/cursor-transcript-bridge.sh
```

### 2. Merge the additive hook entries explicitly

Preserve unrelated entries in the existing `$HOME/.cursor/hooks.json`; do not overwrite the file. The user-level command is relative to `$HOME/.cursor`:

```json
{
  "version": 1,
  "hooks": {
    "sessionStart": [{ "command": "hooks/cursor-transcript-bridge.sh", "timeout": 5 }],
    "beforeSubmitPrompt": [{ "command": "hooks/cursor-transcript-bridge.sh", "timeout": 5 }],
    "afterAgentThought": [{ "command": "hooks/cursor-transcript-bridge.sh", "timeout": 5 }],
    "afterFileEdit": [{ "command": "hooks/cursor-transcript-bridge.sh", "timeout": 5 }],
    "afterShellExecution": [{ "command": "hooks/cursor-transcript-bridge.sh", "timeout": 5 }],
    "afterAgentResponse": [{ "command": "hooks/cursor-transcript-bridge.sh", "timeout": 5 }],
    "stop": [
      { "command": "hooks/cursor-stop-notify.sh", "timeout": 5 },
      { "command": "hooks/cursor-transcript-bridge.sh", "timeout": 5 }
    ]
  }
}
```

For a project-local hook file, use the project-relative commands shown in [`docs/examples/cursor-hooks.json`](docs/examples/cursor-hooks.json): `.cursor/hooks/cursor-stop-notify.sh` and `.cursor/hooks/cursor-transcript-bridge.sh`. User and project hook paths are intentionally different. Never replace either with `${CMUX_AGENT_CONFIG}`.

The stop and after-agent-response callbacks are optional wakeups. A stop error/aborted status is latched for the job, so later success callbacks cannot normalize or rescue it; missing stop does not weaken the fresh transcript, artifact/check, and idle gate. A pathless or not-yet-created transcript is only an observation; a later correlated hook must supply the usable path. Transcript records that expose session/conversation/generation/cwd/workspace/surface identities must match the supervisor mapping.

### 3. Select Cursor

Use the environment default:

```bash
export CMUX_AGENT_EXECUTOR=cursor
```

Or select it per job with `executor_profile: cursor`.

## Configure agy

This repository provides portable templates for the agy wrapper and lifecycle hook, but only the operator can complete their local installation. The machine that runs Pi must have an installed, configured agy CLI and the agy product that needs credentials recorded. Use the included installer (with explicit confirmation) or copy the templates by hand, then register the hook.

### 1. Install the wrapper and adapter

```bash
export CMUX_AGENT_RUNTIME="$HOME/.local/state/cmux-agent"
mkdir -p "$CMUX_AGENT_RUNTIME/jobs" "$CMUX_AGENT_RUNTIME/events"
bash "$repo/docs/examples/agy-install.sh"
```

The installer asks before copying `~/bin/agy-with-permissions` and `~/bin/agy-hook-notify.sh` and before merging the `agy-result-hook` registration into the global agy hooks config. Everything unrelated is preserved.

### 2. Result-file setup

The result source is `${HOME}/agi-result.txt`. The path is fixed by the profile contract so the adapter and the supervisor read the same file; relocating it means changing both the installed adapter and the machine-local `agy.json` `transcript.source` together. The hook creates the file with its first append; no empty placeholder is installed in advance. Confirm the Pi process can read it and can write the runtime event sink.

### 3. Install the profile

```bash
export CMUX_AGENT_CONFIG="$HOME/.config/cmux-agent"
export CMUX_AGENT_PROFILE_DIR="$CMUX_AGENT_CONFIG/profiles"
mkdir -p "$CMUX_AGENT_PROFILE_DIR"
cp "$repo/docs/examples/executor-profile.agy.json" "$CMUX_AGENT_PROFILE_DIR/agy.json"
```

### 4. Select agy

```bash
export CMUX_AGENT_EXECUTOR=agy
```

Or select it per job with `executor_profile: agy`.

A missing agy prerequisite is a configuration failure, not permission to use another CLI automatically.

## Run a job

From Pi, delegate to `cmux-agent` (or an existing alias such as `agy`) with a self-contained job contract. The contract selects the profile, working directory, timeout, markers, and expected artifacts:

```text
<CMUX_AGENT_JOB>
executor_profile: cursor
# For agy, replace the line above with: executor_profile: agy
task: Create cursor-profile-proof.txt containing CURSOR_PROFILE_OK
expected_markers: GOAL_COMPLETE, NEED_APPROVAL, QUESTION, ERROR, STUCK
artifact_expectations: cursor-profile-proof.txt contains CURSOR_PROFILE_OK
cwd: /absolute/path/to/a-disposable-git-checkout
project_name: my-project
worktree_identity: /absolute/path/to/a-disposable-git-checkout
timeout_seconds: 600
job_nonce: <fresh-cryptographically-random-value>
</CMUX_AGENT_JOB>
```

If `executor_profile` is omitted, `CMUX_AGENT_EXECUTOR` must be set. An explicit job profile takes precedence over the environment variable. Missing or invalid selection fails before the prompt is sent.

For a first live check, use a harmless disposable Git directory and ask for exactly one small artifact. Confirm the artifact, fresh nonce-framed transcript marker, accepted lifecycle status, and idle follow-up prompt before trusting the result.

## Switching executors

The common supervisor and cmux routing do not change. Switch only the explicit profile selection:

```bash
export CMUX_AGENT_EXECUTOR=cursor
# or
export CMUX_AGENT_EXECUTOR=agy
```

The same approval, question, timeout, marker, artifact, and fail-closed rules apply to both profiles. Routine reversible prompts may be dismissed safely and recorded; consequential trust, authorization, authentication, spending, destructive, irreversible, ambiguous, or scope-expanding prompts must be escalated.

## Validation and troubleshooting

Run the repository checks from the checkout:

```bash
bash tests/cmux-agent-orchestration-contract.sh
bash tests/executor-profile-contract.sh
bash tests/agy-executor-contract.sh
bash tests/cursor-transcript-bridge-contract.sh
bash -n tests/*.sh docs/examples/*.sh
python3 -m json.tool <each changed JSON file>
git diff --check
```

Common failures:

- **Unknown or missing profile:** set `CMUX_AGENT_EXECUTOR` or add `executor_profile` to the job; verify `<profile-id>.json` exists in `$CMUX_AGENT_PROFILE_DIR`.
- **Cursor bridge/lifecycle source unavailable:** verify both adapters are executable, every hook command uses the correct user/project-relative path, the supervisor mapping is fresh, and `$CMUX_AGENT_RUNTIME` is writable. Do not fall back to screen polling or scan Cursor directories.
- **agy lifecycle source unavailable:** verify the installed wrapper in `~/bin`, the `agy-result-hook` `PostInvocation` registration, and the writable result source. The portable templates come from `docs/examples/`; this repository does not silently install them.
- **Marker appears but job is not accepted:** screen text/prompt echo is not authoritative; inspect the fresh transcript, lifecycle correlation, expected artifact/checks, and idle state.
- **Cursor reports `error` or `aborted`:** the wakeup fails closed even if an artifact was created; inspect the fresh correlated transcript and rerun only after resolving the failure. Missing `stop` is not itself success or failure; the turn-settled gate still requires transcript, artifact/check, and idle evidence.

## Further documentation

- [`docs/index.md`](docs/index.md) — repository documentation entry point.
- [`docs/executor-profiles.md`](docs/executor-profiles.md) — full profile schema, lifecycle contract, safety rules, and validation record.
- [`skills/cmux-agent-orchestration/SKILL.md`](skills/cmux-agent-orchestration/SKILL.md) — detailed supervisor protocol.
- [`docs/examples/`](docs/examples/) — profile and Cursor hook templates.
