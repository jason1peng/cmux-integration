#!/usr/bin/env bash
# Deterministic offline fixtures for the runner-owned result waiter.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
waiter="$root/tools/cmux-agent-wait.py"
[[ -x "$waiter" ]]
python3 -m py_compile "$waiter"

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/cmux-agent-wait.XXXXXX")
trap 'rm -rf -- "$sandbox"' EXIT
mkdir -p "$sandbox/jobs"

write_manifest() {
  local path=$1 nonce=$2 timeout=$3 status=$4
  python3 - "$path" "$nonce" "$timeout" "$status" <<'PY'
import json
import os
from pathlib import Path
import sys
import tempfile
import time

path = Path(sys.argv[1]).absolute()
nonce = sys.argv[2]
timeout = float(sys.argv[3])
status = sys.argv[4]
started = time.time_ns()
value = {
    "schema_version": 1,
    "job_nonce": nonce,
    "status": status,
    "started_at_ns": started,
    "timeout_seconds": timeout,
    "deadline_at_ns": started + int(timeout * 1_000_000_000),
    "stop_deadline_seconds": 0.1,
    "result_path": str(path),
}
path.parent.mkdir(parents=True, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=".result.", dir=str(path.parent))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        fd = -1
        json.dump(value, stream, sort_keys=True, separators=(",", ":"))
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    temporary = ""
finally:
    if fd >= 0:
        os.close(fd)
    if temporary:
        os.unlink(temporary)
PY
}

run_wait() {
  local path=$1 nonce=$2
  set +e
  wait_output=$(python3 "$waiter" --result-path "$path" --job-nonce "$nonce" \
    --poll-interval-seconds 0.01 --safety-margin-seconds 0 \
    --missing-result-grace-seconds 0.05 2>"$sandbox/wait.err")
  wait_status=$?
  set -e
}

# A terminal transition after more than twelve short polling intervals must be
# observed. The fixture replaces the whole manifest atomically.
delayed_path="$sandbox/jobs/delayed/result.json"
write_manifest "$delayed_path" delayed-job 0.5 starting
python3 - "$delayed_path" <<'PY' &
import json
import os
from pathlib import Path
import sys
import tempfile
import time

path = Path(sys.argv[1])
value = json.loads(path.read_text())
time.sleep(0.2)
value["status"] = "completed"
fd, temporary = tempfile.mkstemp(prefix=".result.", dir=str(path.parent))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        fd = -1
        json.dump(value, stream, sort_keys=True, separators=(",", ":"))
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    temporary = ""
finally:
    if fd >= 0:
        os.close(fd)
    if temporary:
        os.unlink(temporary)
PY
publisher=$!
start_ns=$(python3 -c 'import time; print(time.time_ns())')
run_wait "$delayed_path" delayed-job
wait "$publisher"
end_ns=$(python3 -c 'import time; print(time.time_ns())')
[[ "$wait_status" -eq 0 ]]
python3 - "$wait_output" "$start_ns" "$end_ns" <<'PY'
import json
import sys
value = json.loads(sys.argv[1])
assert value["status"] == "completed", value
assert value["terminal"] is True, value
assert int(sys.argv[3]) - int(sys.argv[2]) >= 120_000_000, (value, sys.argv[2:])
PY

# Every supported terminal state is distinct evidence, but the wait operation
# itself succeeds for all terminal manifests; the caller interprets status.
for status in completed failed timed_out cancelled; do
  path="$sandbox/jobs/$status/result.json"
  write_manifest "$path" "terminal-$status" 0.5 "$status"
  run_wait "$path" "terminal-$status"
  [[ "$wait_status" -eq 0 ]]
  python3 - "$wait_output" "$status" <<'PY'
import json
import sys
value = json.loads(sys.argv[1])
assert value["status"] == sys.argv[2], value
assert value["terminal"] is True, value
PY
done

# Malformed JSON, unknown fields/statuses, stale nonces, and a mismatched
# manifest result path all fail closed before any terminal claim.
malformed="$sandbox/jobs/malformed/result.json"
mkdir -p "$(dirname "$malformed")"
printf '{not-json\n' >"$malformed"
run_wait "$malformed" malformed-job
[[ "$wait_status" -eq 2 ]]

unknown="$sandbox/jobs/unknown/result.json"
write_manifest "$unknown" unknown-job 0.5 running
python3 - "$unknown" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["unreviewed_field"] = "must fail closed"
path.write_text(json.dumps(value) + "\n")
PY
run_wait "$unknown" unknown-job
[[ "$wait_status" -eq 2 ]]

unknown_status="$sandbox/jobs/unknown-status/result.json"
write_manifest "$unknown_status" unknown-status-job 0.5 paused
run_wait "$unknown_status" unknown-status-job
[[ "$wait_status" -eq 2 ]]

stale="$sandbox/jobs/stale/result.json"
write_manifest "$stale" actual-job 0.5 completed
run_wait "$stale" different-job
[[ "$wait_status" -eq 2 ]]

mismatched="$sandbox/jobs/mismatched/result.json"
write_manifest "$mismatched" mismatched-job 0.5 completed
python3 - "$mismatched" "$sandbox/jobs/other/result.json" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["result_path"] = str(pathlib.Path(sys.argv[2]).absolute())
path.write_text(json.dumps(value) + "\n")
PY
run_wait "$mismatched" mismatched-job
[[ "$wait_status" -eq 2 ]]

# A running job is not reported incomplete until deadline + stop grace + the
# requested margin, and the waiter never cancels the process.
fence_path="$sandbox/jobs/fence/result.json"
write_manifest "$fence_path" fence-job 0.15 running
(sleep 5) &
child=$!
start_ns=$(python3 -c 'import time; print(time.time_ns())')
set +e
wait_output=$(python3 "$waiter" --result-path "$fence_path" --job-nonce fence-job \
  --poll-interval-seconds 0.01 --safety-margin-seconds 0.15 \
  --missing-result-grace-seconds 0.01 2>"$sandbox/fence.err")
wait_status=$?
set -e
end_ns=$(python3 -c 'import time; print(time.time_ns())')
[[ "$wait_status" -eq 1 ]]
kill -0 "$child"
kill "$child"
wait "$child" 2>/dev/null || true
python3 - "$wait_output" "$start_ns" "$end_ns" <<'PY'
import json
import sys
value = json.loads(sys.argv[1])
assert value["status"] == "incomplete", value
assert value["observed_status"] == "running", value
assert value["terminal"] is False, value
assert int(sys.argv[3]) - int(sys.argv[2]) >= 250_000_000, (value, sys.argv[2:])
PY

echo "cmux-agent-wait contract: PASS"
