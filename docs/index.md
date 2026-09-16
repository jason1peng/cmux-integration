# Documentation index

## Read this first

This repository contains a reusable, framework-neutral headless cmux-agent
skill and its process runner. Before changing it:

1. Read this file.
2. Read [`principles.md`](principles.md).
3. Read [`headless-executor.md`](headless-executor.md).
4. Read the relevant skill, profile, and root instruction files.
5. Run the focused contract tests before submitting changes.

## Documentation SSOT

- Change principles: `docs/principles.md`
- Headless design decision and removed interactive history: `docs/headless-executor.md`
- Profile schema and setup: `docs/executor-profiles.md`
- AI workflow instructions: `AGENTS.md` and `CLAUDE.md`

## Repository map

| Path | Purpose |
| --- | --- |
| `README.md` | User-facing overview, safety boundaries, setup, and verification. |
| `docs/headless-executor.md` | Headless-only design, evidence model, and historical commit reference. |
| `docs/executor-profiles.md` | Machine-local profile schema, supplied templates, and setup. |
| `docs/principles.md` | Repository-wide change and validation principles. |
| `.agents/skills/cmux-agent/SKILL.md` | Framework-neutral workflow for cmux routing, headless launch, result capture, and first-pass checks. |
| `tools/cmux-agent-run.py` | Shell-free process runner with bounded timeout and `result.json`. |
| `tools/cmux-agent-setup.sh` | Explicit plan/apply/check installation of profiles, runner, and runtime directories. |
| `tools/cmux-agent-capability-protocol.py` | Existing optional CLI-neutral capability/task protocol helpers. |
| `adapters/cursor/executor-profile.cursor.json` | Cursor headless profile template. |
| `adapters/agy/executor-profile.agy.json` | agy headless profile template. |
| `tests/cmux-agent-run-contract.sh` | Runner lifecycle, timeout, metadata, and shell-safety fixtures. |
| `tests/cmux-agent-contract.sh` | Headless worker and cmux routing contract checks. |
| `tests/executor-profile-contract.sh` | Profile schema and safety checks. |
| `tests/cmux-agent-setup-contract.sh` | Read-only plan/check and explicit apply setup checks. |
| `tests/cmux-agent-capability-protocol-contract.sh` | Optional capability/task protocol checks. |

## Workflow

1. Keep the calling agent as the final decision-maker.
2. Assign a worker the `cmux-agent` skill for one bounded implementation or
   review task.
3. The host loads `.agents/skills/cmux-agent` (or passes its `SKILL.md`
   explicitly), then the worker uses the official `cmux` and `cmux-workspace`
   skills, resolves the invoking caller's workspace/surface, creates one fresh
   pane beside that surface in the same workspace, and launches only the
   selected headless profile.
4. The runner captures process evidence without parsing provider transcripts or
   screen text.
5. The worker checks declared artifacts and focused checks, then reports paths
   and hashes.
6. The calling agent independently reviews the worktree and repeats important
   checks.

The normal path has no timeline view, Cursor hooks, transcript bridge,
interactive watcher, or screen-only completion gate. The runner's final
manifest and raw output captures are diagnostic evidence; artifact and test
results are correctness evidence.

## Setup boundary

`tools/cmux-agent-setup.sh` is read-only by default. `--apply` requires explicit
confirmation and `--check` never writes. It installs only selected profiles,
the common runner, and runtime directories. It does not
install a CLI, modify hooks, edit shell startup files, create credentials, or
copy job output into the repository.

## Validation

For orchestration changes, run:

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

Use only disposable, harmless live jobs. Record unavailable CLIs or skipped
live checks as limitations rather than silently selecting another profile.
