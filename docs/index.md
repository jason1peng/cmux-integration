# Documentation Index

## Read This First

This repository contains a reusable cmux orchestration skill and its project-scoped Pi subagent configuration.

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

- `docs/` — documentation entry point and repository-wide change principles.
- `skills/` — reusable Pi skills. The cmux orchestration skill is at `skills/cmux-agent-orchestration/SKILL.md`.
- `.pi/agents/` — project-scoped pi-subagents definitions. The thin supervisor is at `.pi/agents/cmux-agent-supervisor.md`.
- `tests/` — contract and regression checks. The orchestration contract test is `tests/cmux-agent-orchestration-contract.sh`.

## File Catalog

| Path | Purpose |
| --- | --- |
| `docs/index.md` | First-stop documentation map and repository workflow. |
| `docs/principles.md` | Source of truth for validation, testing, and maintainability principles. |
| `AGENTS.md` | Root agent guidance pointing to the documentation SSOT. |
| `CLAUDE.md` | Claude-compatible pointer to the same documentation SSOT. |
| `skills/cmux-agent-orchestration/SKILL.md` | Marker-based cmux executor contract, dedicated `cmux-agent` workspace policy, project-labeled new panes, an executor-ready gate before job submission, hybrid push+pull monitoring, escalation discretion for routine prompts, approval routing, lifecycle, failure handling, and verification scenarios. |
| `.pi/agents/cmux-agent-supervisor.md` | Project-scoped low-cost supervisor definition and tool/skill boundaries. |
| `tests/cmux-agent-orchestration-contract.sh` | Static contract validation for markers, hooks, pane targeting, cwd checks, nonce framing, and supervisor restrictions. |

## Agent Workflow

For orchestration changes:

1. Keep the main agent as the decision-maker and the supervisor as a thin launcher/monitor/relay.
2. Reuse the official `cmux` and `cmux-workspace` skills for pane control; do not duplicate pane logic here.
3. Keep all executor jobs in the reusable `cmux-agent` workspace, always create a new pane/surface per job, and label that surface with the authoritative project name plus an ordinal such as `cmux-integration (1)` or `cmux-integration (2)`.
4. Preserve the existing agy wrapper and PostInvocation hook contract.
5. Run `bash tests/cmux-agent-orchestration-contract.sh` and `git diff --check`.
6. For live validation, use a disposable directory and cmux pane; never test destructive or spending actions.
7. Record new verification or runtime limitations in the relevant PR or follow-up documentation.

## How To Add or Update Docs

- Add repository-local plans/specs under `docs/plan/`.
- Update this index whenever docs, skills, agent definitions, or test entry points are added, removed, renamed, or repurposed.
- Keep repo-wide standards in `docs/principles.md`; do not duplicate them across root instruction files.
- Keep root AI instruction files concise and pointing to this index and `docs/principles.md`.
