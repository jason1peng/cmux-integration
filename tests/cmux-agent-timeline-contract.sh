#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
timeline_tool="$root/tools/cmux-agent-timeline.py"
[[ -x "$timeline_tool" ]]
grep -Fq 'cmux-agent.timeline.lock' "$timeline_tool"
grep -Fq 'cmux-agent.timeline.lock' "$root/docs/examples/cursor-result-watcher.sh"
grep -Fq 'cmux-agent.timeline.lock' "$root/docs/examples/cursor-transcript-bridge.sh"
command -v python3 >/dev/null

runtime=$(mktemp -d "${TMPDIR:-/tmp}/cmux-agent-timeline-contract.XXXXXX")
trap 'rm -rf "$runtime"' EXIT
timeline="$runtime/cmux-agent.timeline.ndjson"
nonce="timeline-contract-001"
cwd=$(cd "$root" && pwd -P)

record() {
  python3 "$timeline_tool" record \
    --timeline "$timeline" \
    --job-nonce "$nonce" \
    --workspace workspace:99 \
    --surface surface:100 \
    --cwd "$cwd" \
    "$@" >/dev/null
}

record --event job_started --source supervisor --at-ms 1000
record --event surface_created --source supervisor --at-ms 1100
record --event executor_launched --source supervisor --at-ms 1200
record --event executor_ready --source supervisor --at-ms 1300
record --event prompt_submitted --source supervisor --at-ms 1400
record --event hook_observed --source bridge --at-ms 1500 \
  --detail hook_event_name=sessionStart --detail path_captured=false --detail normalized_records=0
record --event hook_observed --source bridge --at-ms 1600 \
  --detail hook_event_name=afterAgentThought --detail path_captured=true --detail normalized_records=1
record --event state_changed --source watcher --at-ms 1700 --state UNKNOWN --reason bridge-state-missing
record --event observation_changed --source watcher --at-ms 1800 --state UNKNOWN \
  --reason result-missing --detail previous_reason=bridge-state-missing
record --event state_changed --source watcher --at-ms 2000 --state WORKING --reason result-changed
record --event supervisor_observed --source supervisor --at-ms 2100 --state WORKING --reason consumed
record --event state_changed --source watcher --at-ms 3000 --state QUESTION --reason pane-question --question-source pane --quiet-seconds 6.5
record --event question_acknowledged --source supervisor --at-ms 3500 --question-kind approval
record --event question_relayed --source supervisor --at-ms 4000 --question-kind approval
record --event decision_received --source supervisor --at-ms 6000 --outcome approved
record --event response_sent --source supervisor --at-ms 6200
record --event state_changed --source watcher --at-ms 7000 --state WORKING --reason result-changed
record --event supervisor_observed --source supervisor --at-ms 7100 --state IDLE --reason follow-up
record --event completion_gate_passed --source supervisor --at-ms 8000
record --event capability_requested --source supervisor --at-ms 8050 \
  --detail request_id=req-1 --detail capability_id=jira-mr-read \
  --detail capability_kind=local_skill --detail scope_class=local-read-only \
  --detail status=capability-request-budget-exhausted
record --event surface_closed --source supervisor --at-ms 8100
record --event job_finished --source supervisor --at-ms 8200 --outcome success

# Capability events are metadata-only: identity/provenance fields and free-text
# request details cannot be smuggled through the generic --detail channel.
if python3 "$timeline_tool" record --timeline "$timeline" --job-nonce "$nonce" \
  --workspace workspace:99 --surface surface:100 --cwd "$cwd" \
  --event capability_requested --source supervisor --detail reason=secret >/dev/null 2>&1; then
  echo 'capability timeline accepted redacted reason detail' >&2
  exit 1
fi
for reserved in source event job_nonce state status execution_mode; do
  if python3 "$timeline_tool" record --timeline "$timeline" --job-nonce "$nonce" \
    --workspace workspace:99 --surface surface:100 --cwd "$cwd" \
    --event state_changed --source supervisor --detail "$reserved=shadow" >/dev/null 2>&1; then
    echo "timeline accepted reserved detail: $reserved" >&2
    exit 1
  fi
done
if python3 "$timeline_tool" record --timeline "$timeline" --job-nonce "$nonce" \
  --workspace workspace:99 --surface surface:100 --cwd "$cwd" \
  --event capability_requested --source supervisor --status requested --detail status=approved >/dev/null 2>&1; then
  echo 'timeline accepted duplicate capability status ownership' >&2
  exit 1
fi
for invalid in \
  'source --event capability_requested' \
  'status=secret --event capability_requested' \
  'capability_kind=free-form --event capability_requested' \
  'query=leak --event capability_requested'; do
  # Keep the command construction explicit so the negative cases exercise the
  # parser rather than shell interpolation.
  if [[ "$invalid" == source* ]]; then
    if python3 "$timeline_tool" record --timeline "$timeline" --job-nonce "$nonce" \
      --workspace workspace:99 --surface surface:100 --cwd "$cwd" \
      --event capability_requested --source watcher >/dev/null 2>&1; then
      echo 'timeline accepted non-supervisor capability provenance' >&2
      exit 1
    fi
  else
    detail=${invalid%% --event*}
    if python3 "$timeline_tool" record --timeline "$timeline" --job-nonce "$nonce" \
      --workspace workspace:99 --surface surface:100 --cwd "$cwd" \
      --event capability_requested --source supervisor --detail "$detail" >/dev/null 2>&1; then
      echo "timeline accepted invalid capability detail: $detail" >&2
      exit 1
    fi
  fi
done

python3 "$timeline_tool" view --timeline "$timeline" --format markdown > "$runtime/timeline.md"
grep -Fq '| QUESTION |' "$runtime/timeline.md"
grep -Fq 'Detected → acknowledged' "$runtime/timeline.md"
grep -Fq '500ms' "$runtime/timeline.md"
grep -Fq '2.000s' "$runtime/timeline.md"
grep -Fq '## Observation milestones' "$runtime/timeline.md"
grep -Fq 'Prompt → first normalized record' "$runtime/timeline.md"

python3 "$timeline_tool" view --timeline "$timeline" --format json > "$runtime/timeline.json"
python3 - "$runtime/timeline.json" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
assert value["job_nonce"] == "timeline-contract-001"
assert value["total_ms"] == 7200
assert value["state_durations_ms"]["UNKNOWN"] == 300
assert value["state_durations_ms"]["WORKING"] == 2200
assert value["state_durations_ms"]["QUESTION"] == 4000
assert value["prompt_to_first_normalized_ms"] == 200
observation = next(event for event in value["events"] if event["event"] == "observation_changed")
assert observation["state"] == "UNKNOWN"
assert observation["previous_reason"] == "bridge-state-missing"
assert observation["reason"] == "result-missing"
milestones = {item["name"]: item for item in value["milestones"]}
assert milestones["Executor ready"]["elapsed_ms"] == 300
assert milestones["Transcript path captured"]["elapsed_ms"] == 600
assert milestones["First normalized record"]["elapsed_ms"] == 600
assert milestones["Watcher first WORKING"]["elapsed_ms"] == 1000
assert len(value["questions"]) == 1
question = value["questions"][0]
assert question["question_source"] == "pane"
assert question["detected_to_acknowledged_ms"] == 500
assert question["detected_to_relayed_ms"] == 1000
assert question["relayed_to_decision_ms"] == 2000
assert question["decision_to_response_ms"] == 200
assert question["detected_to_resolved_ms"] == 3200
assert question["resolved"] is True
assert all("question text" not in json.dumps(event) for event in value["events"])
PY

html_report="$runtime/timeline.html"
html_repeat="$runtime/timeline-repeat.html"
python3 "$timeline_tool" view --timeline "$timeline" --format html > "$html_report"
python3 "$timeline_tool" view --timeline "$timeline" --format html > "$html_repeat"
cmp -s "$html_report" "$html_repeat"
grep -Fq '<svg class="timeline-svg"' "$html_report"
grep -Fq 'class="event-dot"' "$html_report"
grep -Fq 'DETECTED STATE · watcher' "$html_report"
grep -Fq 'supervisor_observed' "$html_report"
grep -Fq 'Supervisor observations remain as' "$html_report"
grep -Fq 'Hook observations' "$html_report"
grep -Fq 'hook_event_name' "$html_report"
grep -Fq 'normalized_records' "$html_report"
grep -Fq 'Path captured' "$html_report"
grep -Fq 'Observation milestones' "$html_report"
grep -Fq 'Prompt → first normalized record' "$html_report"
grep -Fq 'observation_changed' "$html_report"
grep -Fq 'bridge-state-missing → result-missing' "$html_report"
grep -Fq 'Gap from previous milestone' "$html_report"
if grep -Fq 'SUPERVISOR OBSERVED · assumed' "$html_report"; then
  echo 'timeline HTML rendered a duplicate assumed state track' >&2
  exit 1
fi
grep -Fq 'pointerenter' "$html_report"
grep -Fq 'tooltip.offsetWidth' "$html_report"
grep -Fq 'overflow-x:hidden' "$html_report"
grep -Fq 'max-width:100%' "$html_report"
if grep -Fq 'min-width:900px' "$html_report"; then
  echo 'timeline HTML graph has a fixed width that can exceed its container' >&2
  exit 1
fi
if grep -Fq 'question text' "$html_report"; then
  echo 'timeline HTML leaked prompt/question text' >&2
  exit 1
fi

parallel_timeline="$runtime/parallel.ndjson"
parallel_pids=()
for index in $(seq 1 16); do
  python3 "$timeline_tool" record \
    --timeline "$parallel_timeline" \
    --job-nonce parallel-contract \
    --event supervisor_observed \
    --source supervisor \
    --at-ms "$index" \
    --detail sequence="$index" >/dev/null &
  parallel_pids+=("$!")
done
for pid in "${parallel_pids[@]}"; do
  wait "$pid"
done
[[ "$(wc -l < "$parallel_timeline")" -eq 16 ]]
python3 "$timeline_tool" view --timeline "$parallel_timeline" --format json >/dev/null

printf '%s\n' '{"job_nonce":"other-job","source":"watcher","event":"state_changed","at_ms":9000}' >> "$timeline"
if python3 "$timeline_tool" view --timeline "$timeline" >/dev/null 2>&1; then
  echo 'timeline viewer accepted mixed job nonces' >&2
  exit 1
fi

malformed_timeline="$runtime/malformed.ndjson"
printf '%s\n' '{"schema_version":1,"job_nonce":"timeline-malformed","source":"watcher","event":"state_changed","at_ms":"not-an-integer"}' > "$malformed_timeline"
if python3 "$timeline_tool" view --timeline "$malformed_timeline" >/dev/null 2>&1; then
  echo 'timeline viewer accepted malformed timestamps' >&2
  exit 1
fi

# A finite JSON number can still overflow the millisecond conversion. It must
# take the same controlled malformed-input path rather than escaping as a
# Python traceback from int(infinity).
overflow_timeline="$runtime/overflow.ndjson"
printf '%s\n' '{"schema_version":1,"job_nonce":"timeline-overflow","source":"watcher","event":"state_changed","at":1e308}' > "$overflow_timeline"
overflow_stderr="$runtime/overflow.stderr"
if python3 "$timeline_tool" view --timeline "$overflow_timeline" > /dev/null 2>"$overflow_stderr"; then
  echo 'timeline viewer accepted an overflowing finite timestamp' >&2
  exit 1
fi
grep -Fq 'missing or malformed timestamp' "$overflow_stderr"
if grep -Fq 'Traceback' "$overflow_stderr"; then
  echo 'timeline viewer leaked an OverflowError traceback' >&2
  exit 1
fi

printf 'cmux-agent timeline contract: PASS\n'
