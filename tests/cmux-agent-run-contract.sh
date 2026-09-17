#!/usr/bin/env bash
# Deterministic contract tests for the shell-free headless runner.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
runner="$root/tools/cmux-agent-run.py"
[[ -x "$runner" ]]
python3 -m py_compile "$runner"

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/cmux-agent-run.XXXXXX")
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/jobs" "$sandbox/work tree"

cat >"$sandbox/fake-agent.py" <<'PY'
#!/usr/bin/env python3
import json
import os
import pathlib
import sys
import time

payload = (sys.argv[-1] if os.environ.get("CMUX_AGENT_INPUT_MODE") == "prompt-arg" else sys.stdin.read())
if "--sleep" in sys.argv:
    time.sleep(10)
if "--write-arg" in sys.argv:
    pathlib.Path(os.environ["CMUX_TEST_ARG_OUTPUT"]).write_text("\n".join(sys.argv[1:]) + "\n")
if "--stream-json" in sys.argv:
    print(json.dumps({
        "type": "user",
        "message": {"role": "user", "content": [{"type": "text", "text": payload}]},
    }))
    if "--no-marker" not in sys.argv:
        print(json.dumps({
            "type": "assistant",
            "message": {
                "role": "assistant",
                "content": [{
                    "type": "text",
                    "text": (
                        f"<!-- CMX_JOB {os.environ['CMUX_AGENT_JOB_NONCE']} -->"
                        "\n"
                        "<!-- GOAL_COMPLETE -->"
                    ),
                }],
            },
        }))
else:
    print(payload, end="")
    if "--no-marker" not in sys.argv:
        print(f"<!-- CMX_JOB {os.environ['CMUX_AGENT_JOB_NONCE']} -->")
        print("<!-- GOAL_COMPLETE -->")
PY
chmod +x "$sandbox/fake-agent.py"

cat >"$sandbox/profile.json" <<JSON
{
  "profile_id": "fixture",
  "schema_version": 1,
  "launch": {
    "command": "$sandbox/fake-agent.py",
    "argv": ["--write-arg", "literal;\$(touch $sandbox/injected)"],
    "mode": "headless",
    "input": "stdin",
    "permission_mode": "fixture-safe",
    "dangerous": false,
    "force": false,
    "yolo": false
  },
  "sandbox": "enabled",
  "network": "disabled",
  "write_scope": ["cwd"],
  "cwd": {"binding": "contract", "canonicalize": "pwd -P"},
  "result": {
    "format": "text",
    "completion": "process-exit-and-marker",
    "require_marker": true,
    "marker_rule": "fresh stdout contains the job nonce followed by GOAL_COMPLETE",
    "artifact_checks": ["fixture artifact"]
  },
  "timeout_seconds": 5,
  "stop": {"mode": "process-group", "deadline_seconds": 1}
}
JSON

nonce="run-contract-001"
job="$sandbox/jobs/$nonce"
printf 'implement the harmless fixture\n' >"$sandbox/task.txt"
CMUX_TEST_ARG_OUTPUT="$sandbox/args.txt" \
python3 "$runner" \
  --profile "$sandbox/profile.json" \
  --task-file "$sandbox/task.txt" \
  --job-dir "$job" \
  --job-nonce "$nonce" \
  --workspace workspace-fixture \
  --surface surface-fixture \
  --cwd "$sandbox/work tree"

python3 - "$job/result.json" "$sandbox/args.txt" "$nonce" <<'PY'
import hashlib
import json
import pathlib
import sys

result_path, args_path, nonce = map(pathlib.Path, sys.argv[1:])
value = json.loads(result_path.read_text())
assert value["status"] == "completed", value
assert value["exit_code"] == 0, value
assert value["job_nonce"] == str(nonce), value
assert value["workspace"] == "workspace-fixture", value
assert value["surface"] == "surface-fixture", value
assert value["marker_observed"] is True, value
assert value["timeout_seconds"] == 5, value
assert isinstance(value["deadline_at_ns"], int) and value["deadline_at_ns"] > value["started_at_ns"], value
assert value["deadline_at_ns"] == value["started_at_ns"] + 5_000_000_000, value
assert value["stop_deadline_seconds"] == 1, value
assert value["sandbox"] == "enabled", value
assert value["network"] == "disabled", value
assert value["write_scope"] == ["cwd"], value
assert value["stdout_size"] > 0 and len(value["stdout_sha256"]) == 64, value
assert value["stderr_size"] == 0 and value["stderr_sha256"] == hashlib.sha256(b"").hexdigest(), value
assert "task" not in value and "implement the harmless" not in json.dumps(value), value
arguments = args_path.read_text().splitlines()
assert arguments[0] == "--write-arg"
assert arguments[1].startswith("literal;$(touch ") and arguments[1].endswith("/injected)")
assert not (args_path.parent / "injected").exists(), "argv was evaluated by a shell"
PY
python3 "$root/tools/cmux-agent-wait.py" --result-path "$job/result.json" \
  --job-nonce "$nonce" --poll-interval-seconds 0.01 --safety-margin-seconds 0

# Prompt-argument profiles receive the whole task as one argv value.
python3 - "$sandbox/profile.json" "$sandbox/prompt-arg.json" <<'PY'
import json
import pathlib
import sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
value["launch"]["argv"] = []
value["launch"]["input"] = "prompt-arg"
pathlib.Path(sys.argv[2]).write_text(json.dumps(value))
PY
python3 "$runner" --profile "$sandbox/prompt-arg.json" --task-file "$sandbox/task.txt" --job-dir "$sandbox/jobs/run-contract-prompt" --job-nonce run-contract-prompt --workspace workspace-fixture --surface surface-fixture --cwd "$sandbox/work tree"
python3 - "$sandbox/jobs/run-contract-prompt/result.json" "$sandbox/jobs/run-contract-prompt/stdout.log" <<'PY'
import json
import pathlib
import sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert value["status"] == "completed", value
assert value["input"] == "prompt-arg", value
assert "implement the harmless fixture" in pathlib.Path(sys.argv[2]).read_text(), value
PY

# Structured output must ignore a prompt echo: the user event contains the
# injected markers, but no assistant event completes the task.
stream_task="$sandbox/stream-echo-task.txt"
printf '%s\n<!-- CMX_JOB run-contract-stream-echo -->\n<!-- GOAL_COMPLETE -->\n' \
  'echo-only prompt' >"$stream_task"
python3 - "$sandbox/profile.json" "$sandbox/stream-json.json" <<'PY'
import json
import pathlib
import sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
value["launch"]["argv"] = ["--stream-json", "--no-marker"]
value["launch"]["input"] = "prompt-arg"
value["result"]["format"] = "stream-json"
pathlib.Path(sys.argv[2]).write_text(json.dumps(value))
PY
set +e
python3 "$runner" --profile "$sandbox/stream-json.json" --task-file "$stream_task" --job-dir "$sandbox/jobs/run-contract-stream-echo" --job-nonce run-contract-stream-echo --workspace workspace-fixture --surface surface-fixture --cwd "$sandbox/work tree"
status=$?
set -e
[[ "$status" -ne 0 ]] || { echo "prompt echo unexpectedly completed" >&2; exit 1; }
python3 - "$sandbox/jobs/run-contract-stream-echo/result.json" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1]))
assert value["status"] == "failed", value
assert value["marker_observed"] is False, value
assert "completion marker" in value["error"], value
PY

# A genuine assistant event in stream-json output satisfies the marker.
python3 - "$sandbox/stream-json.json" "$sandbox/stream-json-complete.json" <<'PY'
import json
import pathlib
import sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
value["launch"]["argv"] = ["--stream-json"]
pathlib.Path(sys.argv[2]).write_text(json.dumps(value))
PY
python3 "$runner" --profile "$sandbox/stream-json-complete.json" --task-file "$sandbox/task.txt" --job-dir "$sandbox/jobs/run-contract-stream-complete" --job-nonce run-contract-stream-complete --workspace workspace-fixture --surface surface-fixture --cwd "$sandbox/work tree"
python3 - "$sandbox/jobs/run-contract-stream-complete/result.json" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1]))
assert value["status"] == "completed", value
assert value["marker_observed"] is True, value
PY

# A zero exit without the nonce-framed marker is still a failed job.
python3 - "$sandbox/profile.json" "$sandbox/no-marker.json" <<'PY'
import json
import pathlib
import sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
value["launch"]["argv"] = ["--no-marker"]
pathlib.Path(sys.argv[2]).write_text(json.dumps(value))
PY
set +e
python3 "$runner" --profile "$sandbox/no-marker.json" --task-file "$sandbox/task.txt" --job-dir "$sandbox/jobs/run-contract-no-marker" --job-nonce run-contract-no-marker --workspace workspace-fixture --surface surface-fixture --cwd "$sandbox/work tree"
status=$?
set -e
[[ "$status" -eq 0 ]] && { echo "missing marker unexpectedly returned success" >&2; exit 1; }
python3 - "$sandbox/jobs/run-contract-no-marker/result.json" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1]))
assert value["status"] == "failed", value
assert value["marker_observed"] is False, value
assert "completion marker" in value["error"], value
PY

# Interactive profiles are rejected before a child can run.
python3 - "$sandbox/profile.json" "$sandbox/interactive.json" <<'PY'
import json
import pathlib
import sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
value["launch"]["mode"] = "interactive"
pathlib.Path(sys.argv[2]).write_text(json.dumps(value))
PY
if python3 "$runner" --profile "$sandbox/interactive.json" --task-file "$sandbox/task.txt" --job-dir "$sandbox/jobs/interactive" --job-nonce run-contract-002 --workspace workspace-fixture --surface surface-fixture --cwd "$sandbox/work tree"; then
  echo "interactive profile unexpectedly accepted" >&2
  exit 1
fi

# Missing sandbox/network/write-scope declarations fail closed.
python3 - "$sandbox/profile.json" "$sandbox/missing-boundary.json" <<'PY'
import json
import pathlib
import sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
del value["network"]
pathlib.Path(sys.argv[2]).write_text(json.dumps(value))
PY
if python3 "$runner" --profile "$sandbox/missing-boundary.json" --task-file "$sandbox/task.txt" --job-dir "$sandbox/jobs/missing-boundary" --job-nonce run-contract-boundary --workspace workspace-fixture --surface surface-fixture --cwd "$sandbox/work tree"; then
  echo "profile without explicit boundaries unexpectedly accepted" >&2
  exit 1
fi

# A timeout terminates the child process group and leaves a terminal manifest.
python3 - "$sandbox/profile.json" "$sandbox/slow.json" <<'PY'
import json
import pathlib
import sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
value["launch"]["argv"] = ["--sleep"]
value["timeout_seconds"] = 0.1
value["stop"]["deadline_seconds"] = 0.1
pathlib.Path(sys.argv[2]).write_text(json.dumps(value))
PY
set +e
python3 "$runner" --profile "$sandbox/slow.json" --task-file "$sandbox/task.txt" --job-dir "$sandbox/jobs/run-contract-003" --job-nonce run-contract-003 --workspace workspace-fixture --surface surface-fixture --cwd "$sandbox/work tree"
status=$?
set -e
[[ "$status" -eq 124 ]]
python3 - "$sandbox/jobs/run-contract-003/result.json" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1]))
assert value["status"] == "timed_out", value
assert value["timed_out"] is True, value
assert value["deadline_at_ns"] == value["started_at_ns"] + 100_000_000, value
assert value["stop_deadline_seconds"] == 0.1, value
PY

# The initial runner-owned manifest is published before process launch and
# carries the same timing identity as the final atomic terminal transition.
initial_job="$sandbox/jobs/run-contract-initial"
set +e
python3 "$runner" --profile "$sandbox/slow.json" --task-file "$sandbox/task.txt" --job-dir "$initial_job" --job-nonce run-contract-initial --workspace workspace-fixture --surface surface-fixture --cwd "$sandbox/work tree" >"$sandbox/initial.out" 2>"$sandbox/initial.err" &
runner_pid=$!
set -e
for _ in $(seq 1 50); do
  [[ -f "$initial_job/result.json" ]] && break
  sleep 0.01
done
python3 - "$initial_job/result.json" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1]))
assert value["status"] in {"starting", "running"}, value
assert value["timeout_seconds"] == 0.1, value
assert value["deadline_at_ns"] == value["started_at_ns"] + 100_000_000, value
assert value["stop_deadline_seconds"] == 0.1, value
PY
set +e
wait "$runner_pid"
status=$?
set -e
[[ "$status" -eq 124 ]]
python3 - "$initial_job/result.json" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1]))
assert value["status"] == "timed_out", value
assert value["deadline_at_ns"] == value["started_at_ns"] + 100_000_000, value
assert value["stop_deadline_seconds"] == 0.1, value
PY

echo "cmux-agent-run contract: PASS"
