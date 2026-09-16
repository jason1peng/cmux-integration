# cmux agent integration

This repository provides a framework-neutral `cmux-agent` skill for delegating
one bounded task to a headless coding CLI in a visible
[cmux](https://github.com/manaflow-ai/cmux) pane. Cursor, agy, and other CLIs
are selected through explicit machine-local executor profiles.

A host agent loads the skill to create a pane, launch the configured process,
check the result, and report evidence. The calling agent owns the final review
and verification; this repository does not require a particular agent host.

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
templates. With the default locations, this installs the runner at
`$HOME/.config/cmux-agent/bin/cmux-agent-run.py` and Cursor at
`$HOME/.config/cmux-agent/profiles/cursor.json`; the setup plan prints the
selected path and profile timeout. Setup never edits shell startup files,
Cursor/agy hooks, credentials, transcripts, or timeline files.

## How it works

```text
calling agent
    │ delegates a bounded task
    ▼
cmux-agent skill + worker
    │ resolves the invoking caller's workspace and surface
    ├── creates a fresh project-labelled pane beside the caller
    ├── launches a profile-selected headless CLI through cmux-agent-run.py
    ├── captures stdout/stderr and runner metadata
    └── checks declared artifacts and focused checks
    │ reports evidence
    ▼
calling agent independently reviews the worktree and accepts or rejects it
```

The cmux pane is the execution location and human-visible diagnostic surface.
The executor pane is created beside the caller in the caller's existing
workspace; a new workspace and its unused default pane are never created.
The pane is not a result protocol. The runner starts the child without a shell,
passes the task using the profile's stdin or prompt-argument mode, and enforces
a process-group timeout.

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
artifact and focused checks, and the calling agent independently reviews the
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
- Approval/question/error/scope problems are reported to the calling agent
  rather than answered or approved by guesswork.
- No Cursor transcript directory scanning, hook registration, screen scraping,
  interactive watcher, or provider-specific lifecycle adapter is used.

A profile cannot make an unsafe CLI safe. Review the installed CLI's headless
permission behavior before enabling a profile that can write files or access
external services.

## Profiles

Checked-in templates are portable examples, not personal machine state:

- `adapters/cursor/executor-profile.cursor.json` — Cursor
  `agent --print --output-format stream-json --sandbox enabled --trust` with a
  prompt argument and a 30-minute profile cap.
- `adapters/agy/executor-profile.agy.json` — agy headless profile shape; add
  product-specific headless flags only in the machine-local copy after
  confirming them against the installed product.

See [`docs/executor-profiles.md`](docs/executor-profiles.md) for the schema and
setup details. The reusable skill is
[`.agents/skills/cmux-agent/SKILL.md`](.agents/skills/cmux-agent/SKILL.md). A host
such as Pi can load it for a prompt such as “use a subagent with skill
cmux-agent and cursor to create a Go hello-world file in a temporary folder”;
other agent hosts can use the same skill and profiles. The official `cmux` and
`cmux-workspace` skills remain external prerequisites; this repository does not
duplicate pane-control logic.

## Using from an agent host

This repository contains no host-specific agent manifest. Hosts that support the
Agent Skills layout can discover `.agents/skills/cmux-agent` after the project
is trusted. In Pi, an explicit path also works:

```bash
pi --skill "$PWD/.agents/skills/cmux-agent/SKILL.md"
```

Then use a bounded prompt such as:

```text
Use a subagent with the `cmux-agent` skill and the `cursor` executor profile.
In /tmp/cmux-hello, create hello.go as a minimal Go Hello World program.
Only modify /tmp/cmux-hello. Verify the file contents and run gofmt -d
/tmp/cmux-hello/hello.go and go run /tmp/cmux-hello/hello.go.
```

The host supplies the worker/subagent mechanism; this repository supplies the
skill, runner, and executor profiles. The calling host remains responsible for
final verification.

## Historical interactive implementation

Interactive Cursor/agy execution was intentionally removed from the current
design. The last pre-redesign snapshot is commit **`33e7eb6`**; the original
Cursor interactive bridge started at **`093951b`** and was integrated through
**`959ff9f`**. See [`docs/headless-executor.md`](docs/headless-executor.md) for
what was removed and how to inspect that history without restoring it to the
current tree.

## Repository map

- `.agents/skills/cmux-agent/SKILL.md` — framework-neutral headless cmux worker workflow.
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
bash tests/cmux-agent-contract.sh
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
