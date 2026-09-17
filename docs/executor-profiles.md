# Headless executor profiles

Profiles make the command choice explicit without putting CLI-specific launch
logic in the `cmux-agent` skill. Profiles are machine-local
configuration; the checked-in files under `adapters/` are portable templates.

The current design supports only `mode: headless`. Interactive Cursor/agy
adapters, hooks, transcript discovery, watchers, and timeline views were
removed. See [`headless-executor.md`](headless-executor.md) for the decision and
historical commit reference.

## Selection

Resolve exactly one profile, in this order:

1. `executor_profile` in the job contract;
2. `CMUX_AGENT_EXECUTOR`, when the job omits a profile;
3. no fallback.

The resolver reads only
`${CMUX_AGENT_PROFILE_DIR:-$HOME/.config/cmux-agent/profiles}/<profile-id>.json`.
With the default setup, for example, the Cursor profile is
`$HOME/.config/cmux-agent/profiles/cursor.json`. It never auto-detects an
installed CLI or accepts a command from task text.

## Profile shape

```json
{
  "profile_id": "example",
  "schema_version": 1,
  "launch": {
    "command": "example-agent",
    "argv": ["--headless"],
    "mode": "headless",
    "input": "stdin",
    "permission_mode": "cli-default",
    "dangerous": false,
    "force": false,
    "yolo": false
  },
  "sandbox": "enabled",
  "network": "enabled",
  "write_scope": ["cwd"],
  "cwd": {
    "binding": "contract",
    "canonicalize": "pwd -P"
  },
  "result": {
    "format": "text",
    "completion": "process-exit-and-marker",
    "require_marker": true,
    "marker_rule": "fresh stdout contains the job nonce followed by GOAL_COMPLETE",
    "artifact_checks": ["expected artifact exists", "focused checks pass"]
  },
  "timeout_seconds": 600,
  "stop": {
    "mode": "process-group",
    "deadline_seconds": 10
  }
}
```

The runner validates this contract before launching. For `stream-json`
profiles, completion markers are searched only in assistant-authored text
events, not the echoed user prompt. The runner writes additive timing metadata
(`timeout_seconds`, `deadline_at_ns`, and `stop_deadline_seconds`) in both its
initial and final manifests.

- executable and argv come only from the profile;
- mode is `headless` and input is `stdin` or `prompt-arg`;
- sandbox, network, and write scope are explicit;
- permission behavior is explicit and no flags are added automatically;
- `force`/`yolo` require an explicitly dangerous profile;
- cwd is the canonical job cwd;
- result completion requires process exit plus a nonce-framed marker; and
- timeout and process-group termination are bounded.

A non-zero exit is failure even when output contains a marker. A zero exit or
marker is not sufficient without artifact and focused-check evidence.

## Supplied templates

### Cursor

[`adapters/cursor/executor-profile.cursor.json`](../adapters/cursor/executor-profile.cursor.json)
uses a 1,800-second (30-minute) profile cap and:

```text
agent --print --output-format stream-json --sandbox enabled --trust
```

The prompt is supplied as one argv value because Cursor's `agent --print`
interface accepts a prompt argument. The profile does not add `--force` or
`--yolo`; the operator must explicitly decide how the installed Cursor CLI
handles writes in the selected worktree. A job may request a shorter timeout,
but the runner never lets a job exceed this profile cap.

### agy

[`adapters/agy/executor-profile.agy.json`](../adapters/agy/executor-profile.agy.json)
uses `agy` with an empty fixed argv as a portable headless profile shape. Any
agy-product-specific headless flags must be added to the machine-local copy
after confirming them against the installed product. This repository does not
install agy, credentials, hooks, or a dangerous-mode wrapper.

### Other CLIs

Copy a template to the machine-local profile directory, give it a unique
`profile_id`, and set the trusted executable, fixed headless argv, declared
input/output format, sandbox, network, write scope, permission declaration,
timeout, and stop behavior. Keep the profile
out of Git if it contains private paths or local policy.

## Runner and job evidence

`tools/cmux-agent-run.py` is the common process runner. Setup installs it as
`${CMUX_AGENT_CONFIG}/bin/cmux-agent-run.py`. It uses `shell=False`, passes the
private task file using the profile's input mode, mirrors output to the pane,
captures raw `stdout.log`/`stderr.log`, and writes `result.json` atomically.
The result manifest contains identity, task/output hashes, timestamps, duration,
exit code, timeout state, marker observation, and the effective timeout/deadline
and process-stop grace metadata; it does not contain task text.

`tools/cmux-agent-wait.py` is installed beside the runner. Invoke it with an
explicit `--result-path <job-dir>/result.json` and `--job-nonce`, plus bounded
`--poll-interval-seconds` and `--safety-margin-seconds` values. It reads only
that atomically replaced manifest, rejects malformed/unknown/stale/mismatched
evidence, treats `starting` and `running` as non-terminal, and accepts only
`completed`, `failed`, `timed_out`, and `cancelled` as terminal. The wait fence
is `deadline_at_ns + stop_deadline_seconds + safety margin`. A non-terminal job
is reported incomplete after the fence; the waiter never terminates a process
or converts incomplete evidence into a terminal status. Its exit code is `0`
when any terminal manifest is observed, `1` for incomplete/missing evidence,
and `2` for malformed, stale, or mismatched input; the JSON output always
carries the bounded observed status and result path.

The worker uses the official `cmux` and `cmux-workspace` skills to resolve the
invoking caller's workspace and surface, then creates one fresh terminal pane
beside the caller with `cmux new-split right --workspace <caller-workspace>
--surface <caller-surface> --focus false`. It invokes the runner on the new
surface in that same workspace and resolves its pane by matching the surface
in `list-panes` output. The workspace and surface are explicitly addressed,
but screen output is not parsed as a result. The calling agent independently
verifies the actual worktree and declared checks.

## Setup

The setup command is explicit and read-only by default:

```bash
bash tools/cmux-agent-setup.sh --profile cursor
bash tools/cmux-agent-setup.sh --profile cursor --apply
bash tools/cmux-agent-setup.sh --profile cursor --check
```

Use `--profile agy` or `--profile both` for the other template. Setup creates only selected profile/runtime/bin directories and files; with
no environment overrides, the runner and waiter are installed at
`$HOME/.config/cmux-agent/bin/cmux-agent-run.py` and
`$HOME/.config/cmux-agent/bin/cmux-agent-wait.py`, profiles at
`$HOME/.config/cmux-agent/profiles/<profile-id>.json`, and job evidence under
`$HOME/.local/state/cmux-agent/jobs/<job_nonce>/`. It does not edit Cursor/agy
hooks, shell startup files, credentials, or timeline state. `--check` never
writes. The runner's `--profile` argument is the resolved JSON path, not the
bare profile ID.
