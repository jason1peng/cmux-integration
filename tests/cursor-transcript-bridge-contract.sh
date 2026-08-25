#!/usr/bin/env bash
# Deterministic CMX-004 Cursor hook bridge and low-latency watcher contract.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
examples="$root/docs/examples"
bridge="$examples/cursor-transcript-bridge.sh"
watcher="$examples/cursor-result-watcher.sh"
advisor="$examples/cursor-advisor.sh"
profile="$examples/executor-profile.cursor.json"
hooks="$examples/cursor-hooks.json"
[[ -x "$bridge" ]]
[[ -x "$watcher" ]]
[[ -x "$advisor" ]]
command -v python3 >/dev/null
# The low-latency watcher must use stat/cursor reads, not whole-file polling.
grep -Fq 'MAX_APPEND_READ_BYTES' "$watcher"
grep -Fq 'stream.seek(offset)' "$watcher"
grep -Fq 'ADVISOR_QUIET_SECONDS = 15.0' "$watcher"
grep -Fq 'ADVISOR_BACKOFF_SECONDS = (15.0, 30.0, 60.0)' "$watcher"
grep -Fq 'routine-command-v1' "$watcher"
grep -Fq 'mandatory_escalation_categories' "$profile"
if grep -Fq 'result_path.read_bytes()' "$watcher" || grep -Fq 'event_path.read_text' "$watcher"; then
  echo 'watcher regressed to whole-file result/event polling' >&2
  exit 1
fi

python3 - "$profile" "$hooks" <<'PY'
import json
import re
import sys
from pathlib import Path

profile = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
hooks = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
assert profile["profile_id"] == "cursor"
assert profile["launch"] == {
    "command": "agent",
    "argv": ["--trust"],
    "mode": "interactive",
    "permission_mode": "explicit-trust",
    "dangerous": False,
    "force": False,
    "yolo": False,
}
assert profile["transport"]["prompt"]["submit_key"] == "ctrl+enter"
assert profile["transport"]["continuation"]["submit_key"] == "ctrl+enter"
assert profile["transcript"]["kind"] == "hook-provided-cursor-jsonl"
assert profile["transcript"]["bridge"]["required"] is True
assert "first usable" in profile["transcript"]["bridge"]["path_rule"]
assert "undocumented" in profile["transcript"]["bridge"]["path_rule"]
assert profile["watcher"]["command"] == "${CMUX_AGENT_CONFIG}/bin/cursor-result-watcher.sh"
assert profile["watcher"]["advisor_sink"] == "${CMUX_AGENT_RUNTIME}/jobs/${job_nonce}/cursor.advisor.ndjson"
assert "stat identity" in profile["watcher"]["poll_strategy"]
assert profile["watcher"]["max_append_read_bytes"] == 262144
assert profile["watcher"]["pane_fallback_after_seconds"] == 5
assert set(profile["watcher"]["classifications"]) == {"QUESTION", "IDLE", "WORKING", "LOST", "UNKNOWN"}
advisor = profile["watcher"]["advisor"]
assert advisor["enabled"] == "optional"
assert advisor["kind"] == "bounded-local-llm-advisor"
assert advisor["command"] == "${CMUX_AGENT_CONFIG}/bin/cursor-advisor.sh"
assert advisor["protocol"] == "strict-json-recommendation"
assert advisor["quiet_trigger_after_seconds"] == 15
assert advisor["timeout_seconds"] == 5
assert advisor["backoff_seconds"] == [15, 30, 60]
assert advisor["backoff_cap_seconds"] == 60
assert advisor["policy"] == "routine-command-v1"
assert advisor["mandatory_escalation_categories"] == [
    "destructive", "credential", "deployment", "external-network", "ambiguous", "important"
]
assert profile["lifecycle"]["optional_wakeups"] == ["stop", "afterAgentResponse"]
assert "stop error" in profile["lifecycle"]["optional_stop_status_rule"]
assert set(hooks["hooks"]) == {
    "sessionStart", "beforeSubmitPrompt", "afterAgentThought", "afterFileEdit",
    "afterShellExecution", "afterAgentResponse", "stop",
}
assert hooks["hooks"]["stop"][0]["command"] == ".cursor/hooks/cursor-stop-notify.sh"
assert hooks["hooks"]["stop"][1]["command"] == ".cursor/hooks/cursor-transcript-bridge.sh"
for name, entries in hooks["hooks"].items():
    assert all(entry["timeout"] == 5 for entry in entries), name
    assert all("${CMUX_AGENT_CONFIG}" not in entry["command"] for entry in entries)
assert re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", profile["profile_id"])
print("cursor profile schema bounds: PASS")
PY

runtime=$(mktemp -d "${TMPDIR:-/tmp}/cmux-cursor-bridge-contract.XXXXXX")
trap 'rm -rf "$runtime"' EXIT
nonce="cursor-contract-001"
cwd=$(cd "$root" && pwd -P)
job_dir="$runtime/jobs/$nonce"
mkdir -p "$job_dir" "$runtime/events"
transcript="$runtime/cursor-transcript.jsonl"
python3 - "$job_dir/cursor.mapping.json" "$runtime" "$nonce" "$cwd" <<'PY'
import json
import sys
path, runtime, nonce, cwd = sys.argv[1:]
json.dump({
    "schema_version": 1,
    "job_nonce": nonce,
    "runtime": runtime,
    "workspace": "workspace:99",
    "surface": "surface:100",
    "cwd": cwd,
    "prompt_text": "do it",
    "source": {
        "start_offset": 0,
        "launch_mtime_ns": 1,
        "exists_at_launch": False,
        "created_after_launch": True,
    },
}, open(path, "w", encoding="utf-8"))
PY

run_bridge() {
  local payload=$1
  local path=${2:-}
  local generation=${3:-generation-2}
  local status=${4:-success}
  local transcript_field="null"
  [[ -n "$path" ]] && transcript_field="\"$path\""
  printf '%s\n' "{\"hook_event_name\":\"afterFileEdit\",\"conversation_id\":\"conversation-1\",\"generation_id\":\"$generation\",\"session_id\":\"session-1\",\"transcript_path\":$transcript_field,\"status\":\"$status\"}" | env \
    TMPDIR="$runtime/hook-tmp" CMUX_AGENT_RUNTIME="$runtime/wrong-runtime" CMUX_AGENT_JOB_RUNTIME="$runtime" CMUX_AGENT_JOB_NONCE="$nonce" \
    CMUX_AGENT_WORKSPACE=workspace:99 CMUX_AGENT_SURFACE=surface:100 CMUX_AGENT_CWD="$cwd" "$bridge" >/dev/null
}
mkdir -p "$runtime/hook-tmp"

# Null/future paths are wakeups only.  A later hook supplies the first usable path.
run_bridge "ignored" "" generation-1 success
[[ ! -e "$job_dir/cursor.pty-result.ndjson" ]]
run_bridge "ignored" "" generation-2 success
python3 - "$job_dir/cursor-bridge.state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state["path_captured"] is False
assert state["generation_id"] == "generation-2"
PY

python3 - "$transcript" "$nonce" "$cwd" <<'PY'
import json, sys
path, nonce, cwd = sys.argv[1:]
identities = {
    "conversation_id": "conversation-1",
    "generation_id": "generation-2",
    "session_id": "session-1",
    "cwd": cwd,
    "workspace": "workspace:99",
    "surface": "surface:100",
}
def record(**values):
    return {**identities, **values}
entries = [
    record(id="u-1", role="user", type="user_message", content="Create proof.txt and report completion"),
    record(id="u-short", role="user", type="user_message", content="do it"),
    record(id="a-echo-short", role="assistant", type="assistant_message", content="do it"),
    record(id="a-working", role="assistant", type="assistant_message", content="working"),
    record(id="t-1", role="tool", type="tool_result", content="wrote proof.txt"),
    record(id="a-substring", role="assistant", type="assistant_message", content="I followed the instruction: Create proof.txt and report completion, then verified it."),
    record(id="a-echo", role="assistant", type="assistant_message", content="Create proof.txt and report completion"),
    record(id="a-marker", role="assistant", type="assistant_message", content=f"<!-- CMX_JOB {nonce} -->\n<!-- GOAL_COMPLETE -->"),
]
with open(path, "w", encoding="utf-8") as stream:
    for entry in entries:
        stream.write(json.dumps(entry) + "\n")
PY
# Cursor may expose the path through the documented environment fallback
# rather than the event payload; the same fresh source contract applies.
printf '%s\n' '{"hook_event_name":"afterFileEdit","conversation_id":"conversation-1","generation_id":"generation-2","session_id":"session-1","transcript_path":null,"status":"success"}' | env \
  CMUX_AGENT_RUNTIME="$runtime/wrong-runtime" CMUX_AGENT_JOB_RUNTIME="$runtime" CMUX_AGENT_JOB_NONCE="$nonce" \
  CMUX_AGENT_WORKSPACE=workspace:99 CMUX_AGENT_SURFACE=surface:100 CMUX_AGENT_CWD="$cwd" \
  CURSOR_TRANSCRIPT_PATH="$transcript" "$bridge" >/dev/null
run_bridge ignored "$transcript" generation-2 success
[[ -s "$job_dir/cursor.pty-result.ndjson" ]]
python3 - "$job_dir/cursor.pty-result.ndjson" "$nonce" "$cwd" <<'PY'
import json, re, sys
records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
nonce = sys.argv[2]
assert [entry["role"] for entry in records] == ["assistant", "tool", "assistant", "assistant"]
assert all(entry["job_nonce"] == nonce for entry in records)
assert all(entry["conversation_id"] == "conversation-1" and entry["generation_id"] == "generation-2" for entry in records)
assert all(entry["session_id"] == "session-1" and entry["cwd"] == sys.argv[3] for entry in records)
assert all(entry["workspace"] == "workspace:99" and entry["surface"] == "surface:100" for entry in records)
assert all(isinstance(entry["source_offset"], int) and isinstance(entry["source_end_offset"], int) for entry in records)
assert all(records[i]["source_end_offset"] <= records[i+1]["source_offset"] for i in range(len(records)-1))
joined = "\n".join(entry["content"] for entry in records)
assert "do it" not in joined
assert "I followed the instruction: Create proof.txt and report completion, then verified it." in joined
assert re.search(rf"^<!-- CMX_JOB {re.escape(nonce)} -->$\n^<!-- GOAL_COMPLETE -->$", records[-1]["content"], re.M)
PY

# Replaying the same source is a no-op. A semantic replay with only a timestamp
# changed is also deduplicated, while a later user record is remembered.
before=$(wc -l < "$job_dir/cursor.pty-result.ndjson")
run_bridge ignored "$transcript" generation-2 success
after=$(wc -l < "$job_dir/cursor.pty-result.ndjson")
[[ "$before" -eq "$after" ]]
printf '%s\n' \
  '{"role":"assistant","type":"assistant_message","timestamp_ms":1,"request_id":"one","content":"stable replay"}' \
  '{"role":"assistant","type":"assistant_message","timestamp_ms":2,"request_id":"two","content":"stable replay"}' \
  '{"id":"u-later","role":"user","type":"user_message","content":"later prompt must not be reflected"}' \
  '{"id":"a-later","role":"assistant","type":"assistant_message","content":"later prompt must not be reflected"}' >> "$transcript"
run_bridge ignored "$transcript" generation-2 success
python3 - "$job_dir/cursor.pty-result.ndjson" "$job_dir/cursor-bridge.state.json" <<'PY'
import json, sys
records = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
assert sum(entry["content"] == "stable replay" for entry in records) == 1
assert not any("later prompt" in entry["content"] for entry in records)
state = json.load(open(sys.argv[2], encoding="utf-8"))
assert any("later prompt" in value for value in state["prompt_echoes"])
PY

# Record-level and hook-level identity mismatches, malformed JSONL,
# truncation, and in-place replacement fail closed.
cp "$transcript" "$runtime/transcript.identity-good"
printf '%s\n' '{"id":"foreign-record","role":"assistant","type":"assistant_message","conversation_id":"conversation-1","generation_id":"generation-2","session_id":"session-1","cwd":"'"$cwd"'","workspace":"workspace:foreign","surface":"surface:100","content":"foreign record must not count"}' >> "$transcript"
if run_bridge ignored "$transcript" generation-2 success; then
  echo "bridge accepted a foreign record identity" >&2
  exit 1
fi
cp "$runtime/transcript.identity-good" "$transcript"
if printf '%s\n' '{"hook_event_name":"afterFileEdit","conversation_id":"other","generation_id":"generation-2","session_id":"session-1","transcript_path":"'"$transcript"'"}' | env CMUX_AGENT_RUNTIME="$runtime/wrong-runtime" CMUX_AGENT_JOB_RUNTIME="$runtime" CMUX_AGENT_JOB_NONCE="$nonce" CMUX_AGENT_WORKSPACE=workspace:99 CMUX_AGENT_SURFACE=surface:100 CMUX_AGENT_CWD="$cwd" "$bridge" >/dev/null 2>&1; then
  echo "bridge accepted a foreign conversation" >&2
  exit 1
fi
cp "$transcript" "$runtime/transcript.good"
printf '%s\n' 'not json' >> "$transcript"
if run_bridge ignored "$transcript" generation-2 success; then
  echo "bridge accepted malformed JSONL" >&2
  exit 1
fi
cp "$runtime/transcript.good" "$transcript"
truncate -s 0 "$transcript"
if run_bridge ignored "$transcript" generation-2 success; then
  echo "bridge accepted a truncated transcript" >&2
  exit 1
fi
cp "$runtime/transcript.good" "$transcript"
printf '%s\n' '{"id":"replace","role":"assistant","type":"assistant_message","content":"replacement"}' > "$transcript"
if run_bridge ignored "$transcript" generation-2 success; then
  echo "bridge accepted a replaced transcript" >&2
  exit 1
fi

# Stop errors are wakeups that fail closed: no normalized output is created.
error_runtime=$(mktemp -d "${TMPDIR:-/tmp}/cmux-cursor-stop-error.XXXXXX")
mkdir -p "$error_runtime/jobs/$nonce" "$error_runtime/events" "$error_runtime/hook-tmp"
python3 - "$error_runtime/jobs/$nonce/cursor.mapping.json" "$error_runtime" "$nonce" "$cwd" <<'PY'
import json, sys
p,r,n,c=sys.argv[1:]
json.dump({"schema_version":1,"job_nonce":n,"runtime":r,"workspace":"workspace:11","surface":"surface:12","cwd":c,"source":{"start_offset":0,"launch_mtime_ns":1,"exists_at_launch":False,"created_after_launch":True}},open(p,"w"))
PY
error_source="$error_runtime/error.jsonl"
printf '%s\n' '{"role":"assistant","type":"assistant_message","content":"must not count"}' > "$error_source"
printf '%s\n' "{\"hook_event_name\":\"stop\",\"conversation_id\":\"c-error\",\"generation_id\":\"g-error\",\"session_id\":\"s-error\",\"transcript_path\":\"$error_source\",\"status\":\"error\"}" | env CMUX_AGENT_RUNTIME="$error_runtime/wrong-runtime" CMUX_AGENT_JOB_RUNTIME="$error_runtime" CMUX_AGENT_JOB_NONCE="$nonce" CMUX_AGENT_WORKSPACE=workspace:11 CMUX_AGENT_SURFACE=surface:12 CMUX_AGENT_CWD="$cwd" "$bridge" >/dev/null
[[ ! -e "$error_runtime/jobs/$nonce/cursor.pty-result.ndjson" ]]
grep -Fq '"status":"error"' "$error_runtime/events/cursor-transcript-bridge.ndjson"
if printf '%s\n' "{\"hook_event_name\":\"afterFileEdit\",\"conversation_id\":\"c-error\",\"generation_id\":\"g-error\",\"session_id\":\"s-error\",\"transcript_path\":\"$error_source\",\"status\":\"success\"}" | env CMUX_AGENT_RUNTIME="$error_runtime/wrong-runtime" CMUX_AGENT_JOB_RUNTIME="$error_runtime" CMUX_AGENT_JOB_NONCE="$nonce" CMUX_AGENT_WORKSPACE=workspace:11 CMUX_AGENT_SURFACE=surface:12 CMUX_AGENT_CWD="$cwd" "$bridge" >/dev/null 2>&1; then
  echo "bridge normalized content after a latched stop error" >&2
  exit 1
fi
[[ ! -e "$error_runtime/jobs/$nonce/cursor.pty-result.ndjson" ]]
python3 - "$error_runtime/jobs/$nonce/cursor-bridge.state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state["failure_latched"] is True
assert state["failure_status"] == "error"
PY
watch_error_env=(CMUX_AGENT_RUNTIME="$error_runtime" CMUX_AGENT_JOB_NONCE="$nonce" CMUX_AGENT_WORKSPACE=workspace:11 CMUX_AGENT_SURFACE=surface:12 CMUX_AGENT_CWD="$cwd")
env "${watch_error_env[@]}" "$watcher" --once --pane-fallback-seconds 0 --cmux-command false > "$runtime/watch-latched-error.out"
grep -Fq '"state":"UNKNOWN"' "$runtime/watch-latched-error.out"
grep -Fq '"reason":"bridge-failure-latched"' "$runtime/watch-latched-error.out"
rm -rf "$error_runtime"

# Watcher lifecycle: result activity is WORKING, pane fallback is delayed,
# working indicators outrank follow-up text, and repeated states are silent.
watch_nonce="cursor-watcher-001"
watch_job="$runtime/jobs/$watch_nonce"
watch_transcript="$runtime/watcher-transcript.jsonl"
mkdir -p "$watch_job"
python3 - "$watch_job/cursor.mapping.json" "$runtime" "$watch_nonce" "$cwd" <<'PY'
import json, sys
p,r,n,c=sys.argv[1:]
json.dump({"schema_version":1,"job_nonce":n,"runtime":r,"workspace":"workspace:99","surface":"surface:100","cwd":c,"source":{"start_offset":0,"launch_mtime_ns":1,"exists_at_launch":False,"created_after_launch":True}},open(p,"w"))
PY
printf '%s\n' '{"id":"watch-1","role":"assistant","type":"assistant_message","content":"watching"}' > "$watch_transcript"
watch_env=(CMUX_AGENT_RUNTIME="$runtime" CMUX_AGENT_JOB_NONCE="$watch_nonce" CMUX_AGENT_WORKSPACE=workspace:99 CMUX_AGENT_SURFACE=surface:100 CMUX_AGENT_CWD="$cwd")
printf '%s\n' "{\"hook_event_name\":\"afterAgentThought\",\"conversation_id\":\"conversation-watch\",\"generation_id\":\"generation-watch\",\"session_id\":\"session-watch\",\"transcript_path\":\"$watch_transcript\",\"status\":\"success\"}" | env "${watch_env[@]}" "$bridge" >/dev/null
pane_log="$runtime/pane.log"
pane="$runtime/fake-cmux.sh"
cat > "$pane" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_TEST_PANE_LOG"
printf '%s\n' '→ Add a follow-up'
SH
chmod +x "$pane"
rm -f "$watch_job/cursor-watcher.state.json" "$watch_job/cursor.watcher.ndjson" "$pane_log"
env "${watch_env[@]}" CMUX_TEST_PANE_LOG="$pane_log" "$watcher" --once --pane-fallback-seconds 5 --cmux-command "$pane" > "$runtime/watch-first.out"
grep -Fq '"state":"WORKING"' "$runtime/watch-first.out"
[[ ! -e "$pane_log" ]]
python3 - "$watch_job/cursor-watcher.state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
# The first poll consumed complete lines and recorded cursors for both
# append-only streams; a later poll must not start at byte zero again.
assert state["result_cursor"] == state["result_size"]
assert state["result_cursor"] > 0
assert state["event_cursor"] == state["event_size"]
assert state["event_cursor"] > 0
PY
env "${watch_env[@]}" CMUX_TEST_PANE_LOG="$pane_log" "$watcher" --once --pane-fallback-seconds 5 --cmux-command "$pane" > "$runtime/watch-repeat.out"
[[ ! -s "$runtime/watch-repeat.out" ]]

# Force quiet-time fallback with a pane showing working plus follow-up.
cat > "$pane" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_TEST_PANE_LOG"
printf '%s\n' 'Working…'
printf '%s\n' '→ Add a follow-up'
SH
chmod +x "$pane"
python3 - "$watch_job/cursor-watcher.state.json" <<'PY'
import json, sys
p=sys.argv[1]; s=json.load(open(p)); s["last_activity_at"]=0; s["last_state"]=None; json.dump(s,open(p,"w"),separators=(",",":")); open(p,"a").write("\n")
PY
env "${watch_env[@]}" CMUX_TEST_PANE_LOG="$pane_log" "$watcher" --once --pane-fallback-seconds 0 --cmux-command "$pane" > "$runtime/watch-working-pane.out"
grep -Fq '"state":"WORKING"' "$runtime/watch-working-pane.out"
grep -Fq -- 'read-screen --workspace workspace:99 --surface surface:100' "$pane_log"

# A real follow-up prompt corroborates IDLE, and duplicate IDLE is suppressed.
cat > "$pane" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_TEST_PANE_LOG"
printf '%s\n' '→ Add a follow-up'
SH
chmod +x "$pane"
env "${watch_env[@]}" CMUX_TEST_PANE_LOG="$pane_log" "$watcher" --once --pane-fallback-seconds 0 --cmux-command "$pane" > "$runtime/watch-idle.out"
grep -Fq '"state":"IDLE"' "$runtime/watch-idle.out"
lines_before=$(wc -l < "$watch_job/cursor.watcher.ndjson")
env "${watch_env[@]}" CMUX_TEST_PANE_LOG="$pane_log" "$watcher" --once --pane-fallback-seconds 0 --cmux-command "$pane" > "$runtime/watch-idle-repeat.out"
[[ ! -s "$runtime/watch-idle-repeat.out" ]]
[[ "$lines_before" -eq "$(wc -l < "$watch_job/cursor.watcher.ndjson")" ]]

# QUESTION and unknown/lost states are fail-closed classifications.  The
# bridge appends one transcript/result/event record; the watcher advances its
# cursors instead of reparsing the existing streams.
watch_result_cursor_before=$(python3 - "$watch_job/cursor-watcher.state.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["result_cursor"])
PY
)
watch_event_cursor_before=$(python3 - "$watch_job/cursor-watcher.state.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["event_cursor"])
PY
)
printf '%s\n' '{"id":"watch-question","role":"assistant","type":"assistant_message","content":"<!-- QUESTION --> allow this?"}' >> "$watch_transcript"
printf '%s\n' "{\"hook_event_name\":\"afterAgentThought\",\"conversation_id\":\"conversation-watch\",\"generation_id\":\"generation-watch\",\"session_id\":\"session-watch\",\"transcript_path\":\"$watch_transcript\",\"status\":\"success\"}" | env "${watch_env[@]}" "$bridge" >/dev/null
env "${watch_env[@]}" CMUX_TEST_PANE_LOG="$pane_log" "$watcher" --once --pane-fallback-seconds 5 --cmux-command "$pane" > "$runtime/watch-question.out"
grep -Fq '"state":"QUESTION"' "$runtime/watch-question.out"
python3 - "$watch_job/cursor-watcher.state.json" "$watch_result_cursor_before" "$watch_event_cursor_before" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state["result_cursor"] > int(sys.argv[2])
assert state["event_cursor"] > int(sys.argv[3])
PY
cat > "$pane" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$pane"
printf '%s\n' 'not json' > "$watch_job/cursor.pty-result.ndjson"
rm -f "$watch_job/cursor-watcher.state.json"
env "${watch_env[@]}" CMUX_TEST_PANE_LOG="$pane_log" "$watcher" --once --pane-fallback-seconds 0 --cmux-command "$pane" > "$runtime/watch-unknown.out"
grep -Fq '"state":"UNKNOWN"' "$runtime/watch-unknown.out"

# Optional advisor policy: deterministic allow/deny/malformed fixtures and a
# 15/30/60-second capped backoff that resets after fresh activity.
allow=$(printf '%s\n' '{"schema_version":1,"displayed_command":"git status --short"}' | "$advisor")
deny=$(printf '%s\n' '{"schema_version":1,"displayed_command":"rm -rf proof.txt"}' | "$advisor")
malformed=$(printf '%s\n' 'not-json' | "$advisor")
python3 - "$allow" "$deny" "$malformed" <<'PY'
import json, sys
allow, deny, malformed = (json.loads(value) for value in sys.argv[1:])
assert allow["decision"] == "approve" and allow["category"] == "routine"
assert allow["command"] == "git status --short"
assert deny["decision"] == "escalate" and deny["category"] == "destructive"
assert malformed["decision"] == "escalate" and malformed["category"] == "ambiguous"
PY
advisor_nonce="cursor-advisor-001"
advisor_runtime="$runtime/advisor-runtime"
advisor_job="$advisor_runtime/jobs/$advisor_nonce"
advisor_transcript="$advisor_runtime/advisor-transcript.jsonl"
mkdir -p "$advisor_job" "$advisor_runtime/events"
python3 - "$advisor_job/cursor.mapping.json" "$advisor_runtime" "$advisor_nonce" "$cwd" "$advisor_transcript" <<'PY'
import json, sys
mapping, runtime, nonce, cwd, source = sys.argv[1:]
json.dump({
    "schema_version": 1,
    "job_nonce": nonce,
    "runtime": runtime,
    "workspace": "workspace:99",
    "surface": "surface:100",
    "cwd": cwd,
    "prompt_text": "wait",
    "source": {
        "start_offset": 0,
        "launch_mtime_ns": 1,
        "exists_at_launch": False,
        "created_after_launch": True,
    },
}, open(mapping, "w", encoding="utf-8"))
with open(source, "w", encoding="utf-8") as stream:
    stream.write(json.dumps({
        "id": "advisor-1",
        "role": "assistant",
        "type": "assistant_message",
        "conversation_id": "conversation-advisor",
        "generation_id": "generation-advisor",
        "session_id": "session-advisor",
        "cwd": cwd,
        "workspace": "workspace:99",
        "surface": "surface:100",
        "content": "waiting for a decision",
    }) + "\n")
PY
advisor_pane="$advisor_runtime/fake-cmux.sh"
cat > "$advisor_pane" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'Command: git status --short?'
SH
chmod +x "$advisor_pane"
advisor_response="$advisor_runtime/advisor-response.json"
printf '%s\n' '{"schema_version":1,"policy":"routine-command-v1","decision":"approve","category":"routine","command":"git status --short","reason":"fixture routine command"}' > "$advisor_response"
advisor_command="$advisor_runtime/fake-advisor.sh"
cat > "$advisor_command" <<'SH'
#!/usr/bin/env bash
cat "$CMUX_TEST_ADVISOR_RESPONSE"
SH
chmod +x "$advisor_command"
advisor_env=(
  CMUX_AGENT_RUNTIME="$advisor_runtime"
  CMUX_AGENT_JOB_NONCE="$advisor_nonce"
  CMUX_AGENT_WORKSPACE=workspace:99
  CMUX_AGENT_SURFACE=surface:100
  CMUX_AGENT_CWD="$cwd"
  CMUX_TEST_ADVISOR_RESPONSE="$advisor_response"
)
printf '%s\n' "{\"hook_event_name\":\"afterAgentThought\",\"conversation_id\":\"conversation-advisor\",\"generation_id\":\"generation-advisor\",\"session_id\":\"session-advisor\",\"transcript_path\":\"$advisor_transcript\",\"status\":\"success\"}" | env "${advisor_env[@]}" "$bridge" >/dev/null
env "${advisor_env[@]}" "$watcher" --once --now 100 --pane-fallback-seconds 0 --advisor-quiet-seconds 15 --advisor-command "$advisor_command" --cmux-command "$advisor_pane" > "$advisor_runtime/advisor-first.out"
env "${advisor_env[@]}" "$watcher" --once --now 115 --pane-fallback-seconds 0 --advisor-quiet-seconds 15 --advisor-command "$advisor_command" --cmux-command "$advisor_pane" > "$advisor_runtime/advisor-15.out"
grep -Fq '"type":"advisor"' "$advisor_runtime/advisor-15.out"
grep -Fq '"decision":"approve"' "$advisor_runtime/advisor-15.out"
python3 - "$advisor_job/cursor-watcher.state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state["advisor_attempt"] == 1
assert state["advisor_next_at"] == 130
PY
env "${advisor_env[@]}" "$watcher" --once --now 130 --pane-fallback-seconds 0 --advisor-quiet-seconds 15 --advisor-command "$advisor_command" --cmux-command "$advisor_pane" > "$advisor_runtime/advisor-30.out"
env "${advisor_env[@]}" "$watcher" --once --now 160 --pane-fallback-seconds 0 --advisor-quiet-seconds 15 --advisor-command "$advisor_command" --cmux-command "$advisor_pane" > "$advisor_runtime/advisor-60.out"
python3 - "$advisor_job/cursor-watcher.state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state["advisor_attempt"] == 3
assert state["advisor_next_at"] == 220
PY
# A fresh transcript/event activity resets both the attempt counter and the
# next due time, rather than inheriting the capped backoff from the old turn.
printf '%s\n' '{"id":"advisor-2","role":"assistant","type":"assistant_message","conversation_id":"conversation-advisor","generation_id":"generation-advisor","session_id":"session-advisor","cwd":"'"$cwd"'","workspace":"workspace:99","surface":"surface:100","content":"new activity"}' >> "$advisor_transcript"
printf '%s\n' "{\"hook_event_name\":\"afterAgentThought\",\"conversation_id\":\"conversation-advisor\",\"generation_id\":\"generation-advisor\",\"session_id\":\"session-advisor\",\"transcript_path\":\"$advisor_transcript\",\"status\":\"success\"}" | env "${advisor_env[@]}" "$bridge" >/dev/null
env "${advisor_env[@]}" "$watcher" --once --now 300 --pane-fallback-seconds 0 --advisor-quiet-seconds 15 --advisor-command "$advisor_command" --cmux-command "$advisor_pane" > "$advisor_runtime/advisor-reset.out"
python3 - "$advisor_job/cursor-watcher.state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state["advisor_attempt"] == 0
assert state["advisor_next_at"] is None
PY
# A quiet poll builds advisor backoff again, then a correlated bridge event
# with no normalized result append must reset it just like transcript activity.
env "${advisor_env[@]}" "$watcher" --once --now 315 --pane-fallback-seconds 0 --advisor-quiet-seconds 15 --advisor-command "$advisor_command" --cmux-command "$advisor_pane" > "$advisor_runtime/advisor-event-backoff.out"
python3 - "$advisor_job/cursor-watcher.state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state["advisor_attempt"] == 1
assert state["advisor_next_at"] == 330
PY
printf '%s\n' "{\"hook_event_name\":\"afterAgentThought\",\"conversation_id\":\"conversation-advisor\",\"generation_id\":\"generation-advisor\",\"session_id\":\"session-advisor\",\"transcript_path\":\"$advisor_transcript\",\"status\":\"success\"}" | env "${advisor_env[@]}" "$bridge" >/dev/null
env "${advisor_env[@]}" "$watcher" --once --now 400 --pane-fallback-seconds 0 --advisor-quiet-seconds 15 --advisor-command "$advisor_command" --cmux-command "$advisor_pane" > "$advisor_runtime/advisor-event-reset.out"
python3 - "$advisor_job/cursor-watcher.state.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
assert state["advisor_attempt"] == 0
assert state["advisor_next_at"] is None
PY
# The watcher independently overrides a forged approval for a mandatory
# destructive category, even when the command text matches exactly.
cat > "$advisor_pane" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'Command: rm -rf proof.txt?'
SH
chmod +x "$advisor_pane"
printf '%s\n' '{"schema_version":1,"policy":"routine-command-v1","decision":"approve","category":"routine","command":"rm -rf proof.txt","reason":"forged unsafe approval"}' > "$advisor_response"
printf '%s\n' '{"id":"advisor-3","role":"assistant","type":"assistant_message","conversation_id":"conversation-advisor","generation_id":"generation-advisor","session_id":"session-advisor","cwd":"'"$cwd"'","workspace":"workspace:99","surface":"surface:100","content":"destructive question"}' >> "$advisor_transcript"
printf '%s\n' "{\"hook_event_name\":\"afterAgentThought\",\"conversation_id\":\"conversation-advisor\",\"generation_id\":\"generation-advisor\",\"session_id\":\"session-advisor\",\"transcript_path\":\"$advisor_transcript\",\"status\":\"success\"}" | env "${advisor_env[@]}" "$bridge" >/dev/null
env "${advisor_env[@]}" "$watcher" --once --now 400 --pane-fallback-seconds 0 --advisor-quiet-seconds 15 --advisor-command "$advisor_command" --cmux-command "$advisor_pane" > "$advisor_runtime/advisor-override-first.out"
env "${advisor_env[@]}" "$watcher" --once --now 415 --pane-fallback-seconds 0 --advisor-quiet-seconds 15 --advisor-command "$advisor_command" --cmux-command "$advisor_pane" > "$advisor_runtime/advisor-override.out"
grep -Fq '"decision":"escalate"' "$advisor_runtime/advisor-override.out"
grep -Fq '"category":"destructive"' "$advisor_runtime/advisor-override.out"
# A configured advisor that returns malformed output is a fail-closed
# escalation, not an approval.
cat > "$advisor_pane" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'Command: git status --short?'
SH
chmod +x "$advisor_pane"
printf '%s\n' '{"id":"advisor-4","role":"assistant","type":"assistant_message","conversation_id":"conversation-advisor","generation_id":"generation-advisor","session_id":"session-advisor","cwd":"'"$cwd"'","workspace":"workspace:99","surface":"surface:100","content":"another question"}' >> "$advisor_transcript"
printf '%s\n' "{\"hook_event_name\":\"afterAgentThought\",\"conversation_id\":\"conversation-advisor\",\"generation_id\":\"generation-advisor\",\"session_id\":\"session-advisor\",\"transcript_path\":\"$advisor_transcript\",\"status\":\"success\"}" | env "${advisor_env[@]}" "$bridge" >/dev/null
printf '%s\n' 'not-json' > "$advisor_response"
env "${advisor_env[@]}" "$watcher" --once --now 500 --pane-fallback-seconds 0 --advisor-quiet-seconds 15 --advisor-command "$advisor_command" --cmux-command "$advisor_pane" > "$advisor_runtime/advisor-malformed-first.out"
env "${advisor_env[@]}" "$watcher" --once --now 515 --pane-fallback-seconds 0 --advisor-quiet-seconds 15 --advisor-command "$advisor_command" --cmux-command "$advisor_pane" > "$advisor_runtime/advisor-malformed.out"
grep -Fq '"decision":"escalate"' "$advisor_runtime/advisor-malformed.out"
grep -Fq '"category":"advisor-failure"' "$advisor_runtime/advisor-malformed.out"

# Existing stop adapter remains additive and returns a valid hook response.
stop_runtime=$(mktemp -d "${TMPDIR:-/tmp}/cmux-cursor-stop-contract.XXXXXX")
valid='{"hook_event_name":"stop","status":"completed","conversation_id":"conversation-stop","generation_id":"generation-stop","session_id":"session-stop","transcript_path":null}'
response=$(printf '%s\n' "$valid" | CMUX_AGENT_RUNTIME="$stop_runtime/wrong-runtime" CMUX_AGENT_JOB_RUNTIME="$stop_runtime" "$examples/cursor-stop-notify.sh")
[[ "$response" == '{}' ]]
grep -Fq '"hook_event_name":"stop"' "$stop_runtime/events/cursor-stop.ndjson"
if printf '%s\n' '{"hook_event_name":"beforeSubmitPrompt"}' | CMUX_AGENT_RUNTIME="$stop_runtime/wrong-runtime" CMUX_AGENT_JOB_RUNTIME="$stop_runtime" "$examples/cursor-stop-notify.sh" >/dev/null 2>&1; then
  echo 'stop adapter accepted a non-stop event' >&2
  exit 1
fi
rm -rf "$stop_runtime"

if grep -Eq '/Users/|/home/|/private/|secret|bearer|api[_-]?key|token' "$examples"/*.json "$examples"/*.sh; then
  echo 'Cursor examples leaked private configuration' >&2
  exit 1
fi

echo 'cursor transcript bridge/watcher contract: PASS'
