# Documentation Index

## Read This First

This repository contains a reusable cmux orchestration skill and its project-scoped Pi subagent configuration. For a user-facing quick start, read `README.md`; this file remains the documentation map and source-of-truth entry point for agent work.

Before planning or implementation:

1. Read this file.
2. Read `docs/principles.md`.
3. Read the relevant skill and agent configuration.
4. Read the root AI instruction files when working as an agent.
5. Run the contract test before submitting changes.

## Documentation SSOT

- Change principles: `docs/principles.md`
- Feature plans/specs: `docs/plan/` when project-local plans are added
- Completed work/changelog: not currently maintained in this repository
- AI workflow instructions: `AGENTS.md` and `CLAUDE.md`

## Repository Map

- `README.md` — user-facing introduction, prerequisites, setup, and quick-start usage.
- `docs/` — documentation entry point and repository-wide change principles.
- `skills/` — reusable Pi skills. The cmux orchestration skill is at `skills/cmux-agent-orchestration/SKILL.md`.
- `.pi/agents/` — project-scoped pi-subagents definitions. The generic supervisor is at `.pi/agents/cmux-agent.md` (aliases: `agy`, `cmux-agent-supervisor`).
- `tests/` — contract and regression checks. The orchestration contract test is `tests/cmux-agent-orchestration-contract.sh`.

## File Catalog

| Path | Purpose |
| --- | --- |
| `README.md` | User-facing introduction, prerequisites, setup, and quick-start usage. |
| `docs/index.md` | First-stop documentation map and repository workflow. |
| `docs/principles.md` | Source of truth for validation, testing, and maintainability principles. |
| `AGENTS.md` | Root agent guidance pointing to the documentation SSOT. |
| `CLAUDE.md` | Claude-compatible pointer to the same documentation SSOT. |
| `skills/cmux-agent-orchestration/SKILL.md` | Machine-local executor-profile contract, marker protocol, dedicated `cmux-agent` workspace policy, project-labeled new panes, executor-ready gate before job submission, hybrid push+pull monitoring, correlated lifecycle/result completion gate, escalation discretion for routine prompts, approval routing, lifecycle, failure handling, deferred transports, and verification scenarios. |
| `.pi/agents/cmux-agent.md` | Canonical generic thin supervisor; `agy` and `cmux-agent-supervisor` remain compatibility aliases. |
| `docs/executor-profiles.md` | Profile selection/schema, Cursor interactive stop-hook setup, agy compatibility details, disposable validation evidence, and batch/ACP limitations. |
| `docs/examples/` | Copyable Cursor/agy executor profiles, agy wrapper + PostInvocation lifecycle templates, and an explicit-confirmation installer. These are not machine-local configuration. |
| `tests/agy-executor-contract.sh` | Focused contract checks for the portable agy wrapper, PostInvocation lifecycle adapter, registration fragment, installer merge, and no-secret/no-private-path bounds. |
| `tests/cmux-agent-orchestration-contract.sh` | Static common-protocol, generic-supervisor, alias, pane-targeting, cwd, nonce, and no-screen-only-marker validation. |
| `tests/executor-profile-contract.sh` | Focused JSON-template and profile-specific lifecycle/permission contract validation. |

## Agent Workflow

For orchestration changes:

1. Keep the main agent as the decision-maker and the supervisor as a thin profile resolver/launcher/monitor/relay.
2. Reuse the official `cmux` and `cmux-workspace` skills for pane control; do not duplicate pane logic here.
3. Keep all executor jobs in the reusable `cmux-agent` workspace, always create a new pane/surface per job, and label that surface with the authoritative project name plus an ordinal such as `cmux-integration (1)` or `cmux-integration (2)`.
4. Resolve only an explicit machine-local executor profile or `CMUX_AGENT_EXECUTOR`; never auto-detect a CLI, accept a launch command from task text, silently enable force/yolo, or modify user hooks.
5. Preserve the agy compatibility profile's wrapper, `PostInvocation` hook, transcript, and marker contract; use the generic supervisor aliases for compatibility.
6. Run `bash tests/cmux-agent-orchestration-contract.sh`, `bash tests/executor-profile-contract.sh`, and `git diff --check`.
7. For live validation, use a disposable directory and cmux pane; never test destructive or spending actions. Cursor lifecycle hooks are notifications only and must pass fresh transcript/result, artifact/check, correlation/status, and idle corroboration.
8. Record new verification or runtime limitations, including pending agy validation or deferred batch/ACP adapters, in the relevant change documentation.

## How To Add or Update Docs

- Add repository-local plans/specs under `docs/plan/`.
- Update this index whenever docs, skills, agent definitions, or test entry points are added, removed, renamed, or repurposed.
- Keep repo-wide standards in `docs/principles.md`; do not duplicate them across root instruction files.
- Keep root AI instruction files concise and pointing to this index and `docs/principles.md`.
