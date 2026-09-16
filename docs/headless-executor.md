# Headless executor design

## Decision

`cmux-agent` uses headless CLI processes only. A delegated worker uses the
`cmux-agent` skill to open a fresh pane beside the caller's terminal in the
caller's existing workspace, run one explicitly selected profile, check the
result, and report evidence to the calling agent. The calling agent owns the
final review and verification.

The cmux surface provides visibility and a stable execution location in the
caller's existing workspace. It is not a result channel. Headless stdout/stderr
and the runner-owned `result.json` are execution evidence; the actual worktree
and declared checks are correctness evidence.

## Why interactive execution was removed

The previous transport depended on interactive TUI readiness, Cursor hooks,
provider transcript discovery, transcript normalization, result watchers, idle
heuristics, and timeline rendering. Cursor CLI behavior made that boundary
fragile: a CLI session could emit no `sessionStart` until its first prompt, and
hook `transcript_path` could be null. Those mechanisms are not part of the
headless contract and must not be reintroduced implicitly.

The following are intentionally no longer supported:

- interactive Cursor or agy sessions;
- Cursor hook registration, transcript bridges, transcript bootstrap, stop hooks,
  and result watchers;
- agy lifecycle/result hook adapters and dangerous-mode wrappers;
- screen scraping as a result protocol;
- metadata timelines and HTML timeline views;
- the interactive-only advisor and command-policy integration.

If interactive support is needed later, design it as a separate transport with
its own evidence contract. Do not mix it into the headless runner.

## Historical reference

The last pre-redesign snapshot is commit **`33e7eb6`** (`feat: add safe cmux
agent setup workflow`). It contains the removed interactive implementation and
is the recovery/reference point for the old files. The original interactive
Cursor bridge was introduced by **`093951b`** and integrated through
**`959ff9f`**.

To inspect the old implementation without changing the current checkout:

```bash
git show 33e7eb6:adapters/cursor/cursor-transcript-bridge.sh
git worktree add /tmp/cmux-agent-interactive-reference 33e7eb6
```

The redesign deliberately keeps that history in Git rather than copying the
old code into a compatibility directory. The optional capability protocol also
uses the generic `direct` route name; the former Pi-specific `direct_pi` value
is intentionally not accepted.

## Runtime contract

A profile is machine-local JSON under
`${CMUX_AGENT_PROFILE_DIR:-$HOME/.config/cmux-agent/profiles}`. It declares:

- the executable and fixed argv;
- `mode: headless` and a declared `stdin` or `prompt-arg` input;
- explicit permission/trust behavior;
- explicit sandbox mode, network mode, and write scope;
- contract-cwd binding and canonicalization;
- output format and the completion-marker rule;
- a finite timeout and process-group stop deadline.

The runner starts the command without a shell, passes the private task file
using the profile's stdin or prompt-argument mode, mirrors output to the cmux
surface while capturing it, and writes this machine-local job layout:

```text
$CMUX_AGENT_RUNTIME/jobs/<job_nonce>/
  task.txt       # exact task plus the nonce-framed completion instruction
  stdout.log     # raw CLI stdout, optional diagnostic evidence
  stderr.log     # raw CLI stderr, optional diagnostic evidence
  result.json    # runner-owned final metadata
```

`result.json` records identity, timestamps, duration, exit status, timeout and
termination state, task/output hashes, and whether the expected marker was
observed. It never stores the task text. A successful process and marker do not
prove the task: the worker and calling agent must inspect the expected artifact
and run focused checks.

## Safety boundary

Profile selection is explicit. Task text cannot supply a command, argv, profile,
permission flag, network target, credential, or write scope. The runner uses
`subprocess` with `shell=False`, starts a separate process group, and enforces
the bounded timeout; a job may impose a shorter deadline than the profile
maximum. A profile that enables dangerous behavior must declare it;
the supervisor never adds force/yolo/dangerous flags.

Headless CLIs may not offer interactive approval prompts. If the selected
profile cannot safely express the requested task, or the output reports an
approval/question/error condition, the worker stops and escalates to the calling
agent instead of guessing.

## Verification

The worker reports the result manifest, captured output paths/hashes, cmux
workspace/surface, artifact evidence, and focused-check exit codes. The calling
agent independently reviews the worktree and repeats the important checks.

No transcript scan or timeline view is required for this path. A future
multi-step orchestration requirement may add a small structured event log, but
it must not make provider transcript parsing a dependency again.
