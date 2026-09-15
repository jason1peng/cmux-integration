# cmux agent integration

This repository provides a small Pi skill for delegating one bounded task to a
headless coding CLI in a visible [cmux](https://github.com/manaflow-ai/cmux)
pane. Cursor, agy, and other CLIs are selected through explicit machine-local
executor profiles.

The delegated worker uses the `cmux-agent-orchestration` skill to create a pane,
launch the configured process, check the result, and report evidence to the
main agent. The main agent owns the final review and verification.

## Quick start

Inspect the read-only setup plan first:

```bash
bash tools/cmux-agent-setup.sh --profile cursor
```

Apply only after reviewing and confirming it:

```bash
bash tools/cmux-agent-setup.sh --profile cursor --apply
```

Verify without writing:

```bash
bash tools/cmux-agent-setup.sh --profile cursor --check
```

Use `--profile agy` or `--profile both` to install the corresponding profile
templates. Add `--with-pi` only when explicitly installing the project agent and
skill into the global Pi directory. Setup never edits shell startup files,
Cursor/agy hooks, credentials, transcripts, or timeline files.

## How it works

```text
main Pi agent
    │ delegates a bounded task
    ▼
cmux-agent worker + orchestration skill
    │ reuses the cmux-agent workspace
    ├── creates a fresh project-labelled surface
    ├── launches a profile-selected headless CLI through cmux-agent-run.py
    ├── captures stdout/stderr and runner metadata
    └── checks declared artifacts and focused checks
    │ reports evidence
    ▼
main Pi agent independently reviews the worktree and accepts or rejects it
```

The cmux pane is the execution location and human-visible diagnostic surface.
It is not a result protocol. The runner starts the child without a shell, passes the task using the
profile's stdin or prompt-argument mode, and enforces a process-group timeout.

## Job evidence

Each job uses a fresh nonce and writes machine-local state under:

```text
$CMUX_AGENT_RUNTIME/jobs/<job_nonce>/
  task.txt
  stdout.log
  stderr.log
  result.json
```

`result.json` is runner-owned metadata. It records the profile/job identity,
workspace/surface, canonical cwd, timestamps, duration, child exit code,
timeout/termination state, task/output hashes, and whether the nonce-framed
completion marker was observed. It does not store task text.

A successful process or marker is not enough. The worker checks the expected
artifact and focused checks, and the main agent independently reviews the
actual worktree. Raw output captures are diagnostic artifacts and remain
machine-local.

## Explicit safety boundaries

- The profile is selected explicitly in the job or with `CMUX_AGENT_EXECUTOR`.
- The profile owns the executable and fixed argv; task text cannot add commands,
  flags, profiles, network access, credentials, or write scope.
- Only `mode: headless` profiles using a declared stdin or prompt-argument input are accepted.
- Sandbox mode, network mode, and write scope must be declared by every profile.
- Dangerous, force, and yolo behavior must be declared by the profile; the
  runner never adds those flags.
- Cwd and optional worktree identity are validated before launch.
- The runner uses `subprocess` with `shell=False` and a separate process group.
- Timeouts terminate the process group and preserve the captured evidence.
- Approval/question/error/scope problems are reported to the main agent rather
  than answered or approved by guesswork.
- No Cursor transcript directory scanning, hook registration, screen scraping,
  interactive watcher, or provider-specific lifecycle adapter is used.

A profile cannot make an unsafe CLI safe. Review the installed CLI's headless
permission behavior before enabling a profile that can write files or access
external services.

## Profiles

Checked-in templates are portable examples, not personal machine state:

- `adapters/cursor/executor-profile.cursor.json` — Cursor
  `agent --print --output-format stream-json --trust` with a prompt argument.
- `adapters/agy/executor-profile.agy.json` — agy headless profile shape; add
  product-specific headless flags only in the machine-local copy after
  confirming them against the installed product.

See [`docs/executor-profiles.md`](docs/executor-profiles.md) for the schema and
setup details. The generic worker is
[`.pi/agents/cmux-agent.md`](.pi/agents/cmux-agent.md), and its skill is
[`skills/cmux-agent-orchestration/SKILL.md`](skills/cmux-agent-orchestration/SKILL.md).
The official `cmux` and `cmux-workspace` skills remain external prerequisites;
this repository does not duplicate pane-control logic.

## Historical interactive implementation

Interactive Cursor/agy execution was intentionally removed from the current
design. The last pre-redesign snapshot is commit **`33e7eb6`**; the original
Cursor interactive bridge started at **`093951b`** and was integrated through
**`959ff9f`**. See [`docs/headless-executor.md`](docs/headless-executor.md) for
what was removed and how to inspect that history without restoring it to the
current tree.

## Repository map

- `skills/cmux-agent-orchestration/SKILL.md` — headless cmux worker workflow.
- `.pi/agents/cmux-agent.md` — project-scoped delegated worker definition.
- `tools/cmux-agent-run.py` — shell-free process runner and result manifest.
- `tools/cmux-agent-setup.sh` — explicit plan/apply/check setup.
- `adapters/` — portable headless profile templates.
- `docs/index.md` — documentation entry point.
- `docs/headless-executor.md` — redesign decision and historical reference.
- `tests/` — deterministic profile, runner, setup, orchestration, and protocol
  contract tests.

## Fast verification

```bash
bash tests/cmux-agent-run-contract.sh
bash tests/cmux-agent-orchestration-contract.sh
bash tests/executor-profile-contract.sh
bash tests/cmux-agent-setup-contract.sh
bash tests/cmux-agent-capability-protocol-contract.sh
bash -n tools/cmux-agent-setup.sh tests/*.sh
python3 -m py_compile tools/cmux-agent-run.py tools/cmux-agent-capability-protocol.py
git diff --check
```

Live validation should use a disposable checkout and a harmless artifact. Do
not run destructive, spending, credential-bearing, or network-enabled jobs as
validation.
