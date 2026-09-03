#!/usr/bin/env bash
# Portable additive Cursor hook bridge.
#
# The supervisor creates cursor.mapping.json before launch.  Hook payloads are
# wakeups and identity/path observations only; they never own job routing.  The
# first usable transcript_path is captured and the fresh hook-provided JSONL
# source is normalized into the per-job result.
set -euo pipefail

# Cursor reserves/overwrites CMUX_AGENT_RUNTIME for its own project state.
# Keep the supervisor runtime root (containing jobs/<job_nonce>) on the
# non-colliding variable and retain CMUX_AGENT_RUNTIME only as a
# direct-test/backward-compatible fallback.
runtime_env="${CMUX_AGENT_JOB_RUNTIME:-${CMUX_AGENT_RUNTIME:-}}"
: "${runtime_env:?set the supervisor-generated runtime root}"
export CMUX_AGENT_JOB_RUNTIME="$runtime_env"
: "${CMUX_AGENT_JOB_NONCE:?set the supervisor-generated job nonce}"
: "${CMUX_AGENT_WORKSPACE:?set the supervisor-recorded cmux workspace}"
: "${CMUX_AGENT_SURFACE:?set the supervisor-recorded cmux surface}"
: "${CMUX_AGENT_CWD:?set the supervisor-canonical cwd}"

payload_file=$(mktemp "${TMPDIR:-/tmp}/cmux-cursor-hook.XXXXXX")
trap 'rm -f -- "$payload_file"' EXIT
cat >"$payload_file"

python3 - "$payload_file" <<'PY'
from __future__ import annotations

import datetime as dt
import fcntl
import hashlib
import json
import os
import pathlib
import re
import sys
import tempfile
import time
import uuid
from typing import Any

payload_path = pathlib.Path(sys.argv[1])
ERROR_STATUSES = {"error", "aborted", "failed", "failure"}
ALLOWED_EVENTS = {
    "sessionStart",
    "beforeSubmitPrompt",
    "afterAgentThought",
    "afterFileEdit",
    "afterShellExecution",
    "afterAgentResponse",
    "stop",
}
NONCE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
MAX_TIMELINE_VALUE_LENGTH = 512
HANDLE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
GENERATION_SUFFIX_RE = re.compile(r"^(?P<base>.+)-[0-9]+-[A-Za-z0-9]+$")


def fail(message: str) -> None:
    print(f"cursor transcript bridge: {message}", file=sys.stderr)
    raise SystemExit(2)


def text(value: Any) -> str | None:
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


def first(obj: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        if key in obj:
            return obj[key]
    return None


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value or "\n" in value or "\r" in value:
        fail(f"missing or malformed {name}")
    return value


runtime = pathlib.Path(os.path.realpath(required_env("CMUX_AGENT_JOB_RUNTIME")))
nonce = required_env("CMUX_AGENT_JOB_NONCE")
workspace = required_env("CMUX_AGENT_WORKSPACE")
surface = required_env("CMUX_AGENT_SURFACE")
cwd = pathlib.Path(os.path.realpath(required_env("CMUX_AGENT_CWD")))
if not NONCE_RE.fullmatch(nonce):
    fail("unsafe job nonce")
if not HANDLE_RE.fullmatch(workspace) or not HANDLE_RE.fullmatch(surface):
    fail("workspace and surface must be explicit cmux handles")
if workspace == surface:
    fail("workspace and surface mapping is ambiguous")
if not runtime.is_absolute() or not cwd.is_absolute():
    fail("runtime and cwd must be absolute")

job_dir = runtime / "jobs" / nonce
mapping_path = job_dir / "cursor.mapping.json"
legacy_mapping = job_dir / "mapping.json"
state_path = job_dir / "cursor-bridge.state.json"
result_path = job_dir / "cursor.pty-result.ndjson"
event_path = runtime / "events" / "cursor-transcript-bridge.ndjson"
timeline_path = job_dir / "cmux-agent.timeline.ndjson"
timeline_lock_path = job_dir / ".cmux-agent.timeline.lock"
lock_path = job_dir / ".cursor-transcript-bridge.lock"
if not mapping_path.is_file() or legacy_mapping.exists():
    fail("active supervisor mapping is missing or ambiguous")
try:
    mapping = json.loads(mapping_path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    fail(f"active supervisor mapping is unreadable: {exc}")
if not isinstance(mapping, dict) or mapping.get("schema_version", 1) != 1:
    fail("active supervisor mapping is malformed")
for key, expected in {
    "job_nonce": nonce,
    "workspace": workspace,
    "surface": surface,
}.items():
    if mapping.get(key) != expected:
        fail(f"mapping {key} does not match supervisor-owned value")
if not isinstance(mapping.get("runtime"), str) or os.path.realpath(mapping["runtime"]) != str(runtime):
    fail("mapping runtime does not match supervisor-owned value")
if not isinstance(mapping.get("cwd"), str) or os.path.realpath(mapping["cwd"]) != str(cwd):
    fail("mapping cwd does not match the canonical supervisor cwd")


def nonnegative(value: Any, name: str, default: int | None = None) -> int:
    if value is None and default is not None:
        return default
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        fail(f"mapping {name} is not a non-negative integer")
    return value


def required_bool(value: Any, name: str) -> bool:
    if not isinstance(value, bool):
        fail(f"mapping {name} must be an explicit boolean")
    return value


source_map = mapping.get("source")
if not isinstance(source_map, dict):
    fail("mapping lacks an explicit fresh source boundary")
if "start_offset" not in source_map or "launch_mtime_ns" not in source_map:
    fail("mapping lacks an explicit fresh source boundary")
start_offset = nonnegative(source_map.get("start_offset"), "source.start_offset")
launch_mtime_ns = nonnegative(source_map.get("launch_mtime_ns"), "source.launch_mtime_ns")
if launch_mtime_ns <= 0:
    fail("source.launch_mtime_ns must be positive")
exists_at_launch = required_bool(source_map.get("exists_at_launch"), "source.exists_at_launch")
created_after_launch = required_bool(source_map.get("created_after_launch"), "source.created_after_launch")
if exists_at_launch == created_after_launch:
    fail("source launch/existence boundary is ambiguous")
if start_offset == 0 and (exists_at_launch or not created_after_launch):
    fail("zero source offset requires a source created after launch")
if start_offset > 0 and (not exists_at_launch or created_after_launch):
    fail("appended source boundary must identify an existing source")
map_path = text(source_map.get("path", source_map.get("transcript_path")))
map_device = source_map.get("device")
map_inode = source_map.get("inode")
if exists_at_launch:
    if map_path is None or map_device is None or map_inode is None:
        fail("existing source boundary lacks path/device/inode identity")
    if isinstance(map_device, bool) or not isinstance(map_device, int):
        fail("source.device is malformed")
    if isinstance(map_inode, bool) or not isinstance(map_inode, int):
        fail("source.inode is malformed")
    if nonnegative(source_map.get("size_at_launch"), "source.size_at_launch") != start_offset:
        fail("source offset does not match launch size")
    launch_source_mtime = nonnegative(source_map.get("mtime_ns_at_launch"), "source.mtime_ns_at_launch")
else:
    launch_source_mtime = 0

try:
    event = json.loads(payload_path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    fail(f"hook payload is malformed: {exc}")
if not isinstance(event, dict):
    fail("hook payload is not an object")
hook_name = text(first(event, "hook_event_name", "event_name", "event"))
if hook_name not in ALLOWED_EVENTS:
    fail("unexpected Cursor hook event")
status = text(first(event, "status", "hook_status")) or "observed"
status_lower = status.casefold()


IDENTITY_ALIASES: dict[str, tuple[str, ...]] = {
    "job_nonce": ("job_nonce", "jobNonce"),
    "executor_session": ("executor_session", "executorSession", "session_id", "sessionId"),
    "conversation_id": ("conversation_id", "conversationId", "conversationID"),
    "generation_id": ("generation_id", "generationId", "generationID", "turn_id", "turnId"),
    "session_id": ("session_id", "sessionId", "sessionID"),
    "cwd": (
        "cwd",
        "working_directory",
        "workingDirectory",
        "current_working_directory",
        "currentWorkingDirectory",
    ),
    "workspace": ("workspace", "workspace_id", "workspaceId", "cmux_workspace", "cmuxWorkspace"),
    "surface": ("surface", "surface_id", "surfaceId", "cmux_surface", "cmuxSurface"),
}
IDENTITY_NESTED_KEYS = ("metadata", "context", "identities", "identity", "routing")


def identity_value(obj: dict[str, Any], field: str, *, required: bool = False) -> str | None:
    aliases = IDENTITY_ALIASES[field]
    value = first(obj, *aliases)
    if value is None:
        for nested_key in IDENTITY_NESTED_KEYS:
            nested = obj.get(nested_key)
            if isinstance(nested, dict):
                value = first(nested, *aliases)
                if value is not None:
                    break
    if value is None:
        if required:
            fail(f"identity field {field} is missing")
        return None
    if field == "cwd":
        value = text(value)
        if value is None or "\n" in value or "\r" in value:
            fail(f"identity field {field} is malformed")
        value = os.path.realpath(value)
        if not os.path.isabs(value):
            fail(f"identity field {field} is not absolute")
        return value
    value = text(value)
    if value is None or "\n" in value or "\r" in value:
        fail(f"identity field {field} is malformed")
    return value


def event_text(*keys: str) -> str | None:
    return text(first(event, *keys))


conversation = identity_value(event, "conversation_id") or ""
generation = identity_value(event, "generation_id") or ""
session = identity_value(event, "session_id") or identity_value(event, "executor_session") or ""
if not conversation and not session:
    fail("hook payload lacks session/conversation identity")
for key, expected in {
    "job_nonce": nonce,
    "workspace": workspace,
    "surface": surface,
    "cwd": str(cwd),
}.items():
    supplied = identity_value(event, key)
    if supplied is not None and supplied != expected:
        fail(f"hook payload attempted to override mapping {key}")

job_dir.mkdir(parents=True, exist_ok=True)
event_path.parent.mkdir(parents=True, exist_ok=True)
try:
    lock = lock_path.open("a+")
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
except OSError as exc:
    fail(f"cannot lock bridge state: {exc}")


def read_state() -> dict[str, Any]:
    if not state_path.exists():
        return {}
    try:
        value = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        fail(f"bridge state is malformed: {exc}")
    if not isinstance(value, dict) or value.get("schema_version", 1) != 1:
        fail("bridge state is malformed")
    if value.get("job_nonce") != nonce or value.get("mapping_path") != str(mapping_path):
        fail("bridge state belongs to another job")
    return value


state = read_state()
old_conversation = text(state.get("conversation_id"))
old_generation = text(state.get("generation_id"))
old_session = text(state.get("session_id"))
path_captured = state.get("path_captured") is True
failure_latched = state.get("failure_latched") is True
if old_conversation and conversation and old_conversation != conversation:
    fail("hook conversation does not match the active job")
if old_session and session and old_session != session:
    fail("hook session does not match the active job")
if old_generation and generation and old_generation != generation:
    old_family = GENERATION_SUFFIX_RE.fullmatch(old_generation)
    new_family = GENERATION_SUFFIX_RE.fullmatch(generation)
    same_family = (old_family.group("base") if old_family else old_generation) == (
        new_family.group("base") if new_family else generation
    )
    # Cursor can advance the generation at prompt submission and decorate it
    # for individual blocks.  Before path capture that rollover is expected;
    # after capture an unrelated generation fails closed.
    if path_captured and not same_family:
        fail("hook generation does not match the active job")

prompt_values = state.get("prompt_echoes", [])
if not isinstance(prompt_values, list) or any(not isinstance(item, str) for item in prompt_values):
    fail("bridge prompt state is malformed")
prompt_echoes = [item for item in prompt_values if item]
for candidate in (mapping.get("prompt_text"), mapping.get("submitted_prompt")):
    value = text(candidate)
    if value and value not in prompt_echoes:
        prompt_echoes.append(value)
# Keep persisted prompt text bounded.
prompt_echoes = prompt_echoes[-32:]


def source_from_event() -> str | None:
    value = event_text("transcript_path", "transcriptPath", "canonical_transcript_path")
    if value in (None, "null"):
        value = text(os.environ.get("CURSOR_TRANSCRIPT_PATH"))
    if not value:
        return None
    try:
        path = pathlib.Path(os.path.realpath(value))
        if not path.is_file() or not os.access(path, os.R_OK):
            return None
    except OSError:
        return None
    return str(path)


raw_source = source_from_event()

def generation_family(value: str) -> str:
    match = GENERATION_SUFFIX_RE.fullmatch(value)
    return match.group("base") if match else value


def event_identity(path: str | None, size: int | None) -> str:
    supplied = event_text("event_id", "eventId")
    if supplied:
        return supplied
    data = {
        "hook_event_name": hook_name,
        "executor_session": session or conversation,
        "conversation_id": conversation,
        "generation_id": generation,
        "session_id": session,
        "transcript_path": path,
        "transcript_size": size,
        "status": status,
    }
    return hashlib.sha256(json.dumps(data, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def timeline_field(value: Any) -> Any:
    if isinstance(value, str):
        if 0 < len(value) <= MAX_TIMELINE_VALUE_LENGTH and "\n" not in value and "\r" not in value:
            return value
        return None
    if value is None or isinstance(value, (bool, int, float)):
        return value
    return None


def append_timeline(
    event_name: str,
    event_at: float | None = None,
    event_monotonic_ns: int | None = None,
    **fields: Any,
) -> None:
    # This adapter is copied to a machine-local hook path and must remain
    # self-contained; the checked-in CLI is the matching record/view tool,
    # not a runtime dependency of the hook bridge. Timeline data is diagnostic
    # only; do not turn a telemetry write failure into a false Cursor hook
    # failure or alter the completion gate.
    observed_at = event_at if isinstance(event_at, (int, float)) and not isinstance(event_at, bool) else time.time()
    observed_monotonic_ns = (
        event_monotonic_ns
        if isinstance(event_monotonic_ns, int) and not isinstance(event_monotonic_ns, bool) and event_monotonic_ns >= 0
        else time.monotonic_ns()
    )
    try:
        timeline_at = dt.datetime.fromtimestamp(observed_at, dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        timeline_at_ms = int(observed_at * 1000)
    except (OverflowError, ValueError):
        return
    value: dict[str, Any] = {
        "schema_version": 1,
        "event_id": f"bridge:{observed_monotonic_ns}:{uuid.uuid4().hex[:12]}",
        "job_nonce": nonce,
        "source": "bridge",
        "event": event_name,
        "at": timeline_at,
        "at_ms": timeline_at_ms,
        "monotonic_ns": observed_monotonic_ns,
        "workspace": workspace,
        "surface": surface,
        "cwd": str(cwd),
    }
    for key in (
        "hook_event_name",
        "status",
        "path_captured",
        "normalized_records",
        "failure_latched",
    ):
        field = timeline_field(fields.get(key))
        if field is not None:
            value[key] = field
    line = json.dumps(value, separators=(",", ":"), ensure_ascii=False)
    try:
        timeline_path.parent.mkdir(parents=True, exist_ok=True)
        with timeline_lock_path.open("a+", encoding="utf-8") as lock_stream:
            fcntl.flock(lock_stream.fileno(), fcntl.LOCK_EX)
            with timeline_path.open("a", encoding="utf-8") as stream:
                stream.write(line + "\n")
                stream.flush()
    except OSError as exc:
        print(f"cursor transcript bridge: timeline append unavailable: {exc}", file=sys.stderr)


def append_event(path: str | None, size: int | None, records: int, captured: bool) -> None:
    observed_at = time.time()
    observed_monotonic_ns = time.monotonic_ns()
    value = {
        "schema_version": 1,
        "hook_event_name": hook_name,
        "hook": "cursor-transcript-bridge",
        "event_id": event_identity(path, size),
        "executor_session": session or conversation,
        "conversation_id": conversation,
        "generation_id": generation,
        "session_id": session,
        "status": status,
        "transcript_path": path,
        "transcript_offset": state.get("last_source_offset", start_offset),
        "transcript_size": size,
        "normalized_records": records,
        "path_captured": captured,
        "observed_at": observed_at,
        "observed_monotonic_ns": observed_monotonic_ns,
        # These are copied from supervisor mapping, never sourced from the hook.
        "job_nonce": nonce,
        "workspace": workspace,
        "surface": surface,
        "cwd": str(cwd),
    }
    with event_path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(value, separators=(",", ":")) + "\n")
    append_timeline(
        "hook_observed",
        event_at=observed_at,
        event_monotonic_ns=observed_monotonic_ns,
        hook_event_name=hook_name,
        status=status,
        path_captured=captured,
        normalized_records=records,
        failure_latched=state.get("failure_latched") is True,
    )


def write_state(value: dict[str, Any]) -> None:
    temp_fd, temp_name = tempfile.mkstemp(prefix="cursor-bridge-state.", dir=str(job_dir))
    os.close(temp_fd)
    temp_path = pathlib.Path(temp_name)
    try:
        temp_path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
        os.replace(temp_path, state_path)
    finally:
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass


# A failed stop/status is terminal for this job.  Keep the latch in the
# supervisor-owned state so a later success/afterAgentThought wakeup cannot
# normalize a result after Cursor already reported an error or abort.
if status_lower in ERROR_STATUSES:
    failed_state = dict(state)
    failed_state.update(
        {
            "schema_version": 1,
            "job_nonce": nonce,
            "mapping_path": str(mapping_path),
            "conversation_id": conversation or old_conversation or "",
            "generation_id": generation or old_generation or "",
            "session_id": session or old_session or "",
            "prompt_echoes": prompt_echoes,
            "path_captured": path_captured,
            "failure_latched": True,
            "failure_status": status_lower,
            "failure_hook_event": hook_name,
            "failure_event_id": event_identity(raw_source, None),
            "failure_transcript_path": raw_source,
            "events_seen": nonnegative(state.get("events_seen"), "state.events_seen", 0) + 1,
        }
    )
    write_state(failed_state)
    state = failed_state
    append_event(raw_source, None, 0, bool(path_captured))
    raise SystemExit(0)

# Once an error/aborted status has been observed, all later hook callbacks are
# wakeups only.  Refuse to append result records and leave the failed state
# visible to the watcher/supervisor.
if failure_latched:
    append_event(raw_source, None, 0, bool(path_captured))
    fail("job failure was already latched; refusing later transcript content")

if raw_source is None:
    state.update(
        {
            "schema_version": 1,
            "job_nonce": nonce,
            "mapping_path": str(mapping_path),
            "conversation_id": conversation or old_conversation or "",
            "generation_id": generation or old_generation or "",
            "session_id": session or old_session or "",
            "prompt_echoes": prompt_echoes,
            "path_captured": path_captured,
            "events_seen": nonnegative(state.get("events_seen"), "state.events_seen", 0) + 1,
        }
    )
    write_state(state)
    append_event(None, None, 0, path_captured)
    raise SystemExit(0)

source = pathlib.Path(raw_source)
try:
    source_stat = source.stat()
except OSError as exc:
    fail(f"cannot stat transcript source: {exc}")
if not source.is_file() or not os.access(source, os.R_OK):
    fail("transcript source is missing or unreadable")
if map_path is not None and os.path.realpath(map_path) != str(source):
    fail("hook transcript path does not match mapped source")
if exists_at_launch:
    if source_stat.st_dev != map_device or source_stat.st_ino != map_inode:
        fail("transcript source identity was replaced")
    if source_stat.st_size < start_offset:
        fail("transcript source was truncated before launch boundary")
    if source_stat.st_mtime_ns < launch_source_mtime:
        fail("transcript source mtime predates launch")
else:
    if source_stat.st_mtime_ns < launch_mtime_ns:
        fail("new transcript source predates launch")
    birth = getattr(source_stat, "st_birthtime_ns", None)
    if birth is None:
        birth = getattr(source_stat, "st_ctime_ns", None)
    if birth is not None and birth < launch_mtime_ns:
        fail("new transcript source identity predates launch")

old_path = text(state.get("transcript_path"))
if old_path and old_path != str(source):
    fail("transcript path changed during the active job")
old_device = state.get("source_device")
old_inode = state.get("source_inode")
if old_device is not None and old_device != source_stat.st_dev:
    fail("transcript source device changed")
if old_inode is not None and old_inode != source_stat.st_ino:
    fail("transcript source inode changed")
last_offset = nonnegative(state.get("last_source_offset"), "state.last_source_offset", start_offset)
if last_offset < start_offset or source_stat.st_size < last_offset:
    fail("transcript source was truncated or replaced")
previous_mtime = state.get("source_mtime_ns")
if previous_mtime is not None and source_stat.st_mtime_ns < previous_mtime:
    fail("transcript source mtime moved backwards")
try:
    raw = source.read_bytes()
except OSError as exc:
    fail(f"cannot read transcript source: {exc}")


def checkpoint(data: bytes, end: int) -> str:
    window = 65536
    prefix = data[: min(end, window)]
    suffix = data[max(0, end - window) : end]
    return hashlib.sha256(str(end).encode() + b"\0" + prefix + b"\0" + suffix).hexdigest()


previous_checkpoint = text(state.get("source_checkpoint"))
if previous_checkpoint and previous_checkpoint != checkpoint(raw, last_offset):
    fail("transcript source prefix was replaced")
new_bytes = raw[last_offset:]
complete_end = last_offset
lines: list[tuple[int, int, bytes]] = []
for piece in new_bytes.splitlines(keepends=True):
    end = complete_end + len(piece)
    if not piece.endswith((b"\n", b"\r")):
        break
    lines.append((complete_end, end, piece.rstrip(b"\r\n")))
    complete_end = end


def role_and_kind(entry: dict[str, Any]) -> tuple[str, str]:
    message = entry.get("message")
    nested = message.get("role") if isinstance(message, dict) else None
    role = text(first(entry, "role", "source", "author")) or text(nested) or ""
    kind = text(first(entry, "type", "event_type", "kind")) or ""
    return role.casefold(), kind.casefold()


def stringify(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float, bool)):
        return str(value)
    if isinstance(value, list):
        parts = [stringify(item) for item in value]
        return "\n".join(item for item in parts if item)
    if isinstance(value, dict):
        for key in ("text", "content", "value", "output"):
            if key in value:
                rendered = stringify(value[key])
                if rendered:
                    return rendered
        return ""
    return ""


def content_for(entry: dict[str, Any]) -> str:
    for candidate in (
        entry.get("content"),
        entry.get("text"),
        entry.get("message"),
        entry.get("output"),
        entry.get("tool_result"),
        entry.get("tool_call"),
    ):
        value = stringify(candidate)
        if value:
            return value
    return ""


def validate_record_identity(entry: dict[str, Any]) -> None:
    """Reject transcript records that claim a different active execution.

    Cursor transcript formats have changed field names between releases, so
    identity_value accepts the documented top-level/nested aliases.  Records
    from older formats may omit these optional fields; when a record supplies
    one, however, it must agree with the hook identity and supervisor mapping.
    """
    supplied_nonce = identity_value(entry, "job_nonce")
    if supplied_nonce is not None and supplied_nonce != nonce:
        fail("transcript record job nonce does not match the active job")

    expected: dict[str, str | None] = {
        "conversation_id": conversation or old_conversation or None,
        "generation_id": generation or old_generation or None,
        "session_id": session or old_session or None,
        "cwd": str(cwd),
        "workspace": workspace,
        "surface": surface,
    }
    actual_fields = (
        "conversation_id",
        "generation_id",
        "session_id",
        "cwd",
        "workspace",
        "surface",
    )
    for field in actual_fields:
        actual = identity_value(entry, field)
        if actual is None:
            continue
        wanted = expected[field]
        if wanted is None:
            fail(f"transcript record {field} cannot be correlated to the hook")
        if field == "generation_id":
            if generation_family(actual) != generation_family(wanted):
                fail(f"transcript record {field} does not match the hook generation")
        elif actual != wanted:
            fail(f"transcript record {field} does not match the active mapping")

    executor_session = identity_value(entry, "executor_session")
    if executor_session is not None:
        allowed_sessions = {
            value for value in (session, old_session, conversation, old_conversation) if value
        }
        if executor_session not in allowed_sessions:
            fail("transcript record executor session does not match the hook")


VOLATILE_KEYS = {
    "attempt", "attempt_id", "created_at", "createdat", "duration", "duration_ms",
    "elapsed_ms", "event_id", "eventid", "latency_ms", "request_id", "requestid",
    "response_id", "responseid", "retry", "retry_id", "retryid", "timestamp",
    "timestamp_ms", "timestamp_ns", "trace_id", "traceid", "updated_at", "updatedat",
    "usage",
}


def semantic(value: Any) -> Any:
    if isinstance(value, dict):
        return {k: semantic(v) for k, v in value.items() if str(k).casefold() not in VOLATILE_KEYS}
    if isinstance(value, list):
        return [semantic(v) for v in value]
    return value


def identity(entry: dict[str, Any]) -> str:
    for key in ("id", "message_id", "messageId", "step_index", "sequence"):
        value = entry.get(key)
        if isinstance(value, (str, int)) and not isinstance(value, bool):
            return f"{key}:{value}"
    digest = hashlib.sha256(json.dumps(semantic(entry), sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return f"semantic:{digest}"


def normalize_text(value: str) -> str:
    return value.replace("\r\n", "\n").replace("\r", "\n").strip()


def strip_echo(value: str, echoes: list[str]) -> str:
    normalized = normalize_text(value)
    if not normalized:
        return ""
    lines = normalized.split("\n")
    blocks = []
    for echo in echoes:
        echo = normalize_text(echo)
        if not echo:
            continue
        if normalized == echo:
            return ""
        blocks.append([line.strip() for line in echo.split("\n")])
    for block in sorted(blocks, key=len, reverse=True):
        index = 0
        while index <= len(lines) - len(block):
            if [line.strip() for line in lines[index : index + len(block)]] == block:
                del lines[index : index + len(block)]
            else:
                index += 1
    return "\n".join(lines).strip()


# Parse all records before filtering so a user record and its reflection in the
# same callback are handled consistently.
parsed: list[tuple[int, int, dict[str, Any], str, str, str]] = []
new_echoes = list(prompt_echoes)
for start, end, line in lines:
    if not line.strip():
        continue
    try:
        entry = json.loads(line.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        fail(f"malformed Cursor transcript JSONL at offset {start}: {exc}")
    if not isinstance(entry, dict):
        fail(f"Cursor transcript record at offset {start} is not an object")
    # Validate identity before filtering user/prompt records as well.  A
    # foreign record must never be hidden by normalization or echo removal.
    validate_record_identity(entry)
    role, kind = role_and_kind(entry)
    content = content_for(entry)
    if not content:
        continue
    if entry.get("is_prompt") is True or entry.get("prompt") is True or any(word in f"{role} {kind}" for word in ("user", "human", "prompt")):
        if content not in new_echoes:
            new_echoes.append(content)
        continue
    parsed.append((start, end, entry, role, kind, content))
new_echoes = new_echoes[-32:]
seen = state.get("seen_entries", {})
if not isinstance(seen, dict):
    fail("bridge deduplication state is malformed")
seen = dict(seen)
records: list[dict[str, Any]] = []
for start, end, entry, role, kind, content in parsed:
    content = strip_echo(content, new_echoes)
    if not content:
        continue
    if not any(word in f"{role} {kind}" for word in ("assistant", "model", "tool", "function", "response", "output")):
        continue
    entry_id = identity(entry)
    if entry_id in seen:
        continue
    record = {
        "schema_version": 1,
        "job_nonce": nonce,
        "executor_session": session or conversation,
        "conversation_id": conversation or old_conversation or "",
        "generation_id": generation or old_generation or "",
        "session_id": session or old_session or "",
        "cwd": str(cwd),
        "workspace": workspace,
        "surface": surface,
        "source_path": str(source),
        "source_offset": start,
        "source_end_offset": end,
        "role": role or ("tool" if "tool" in kind else "assistant"),
        "type": kind or "output",
        "content": content,
    }
    records.append(record)
    seen[entry_id] = end

if records:
    try:
        with result_path.open("a", encoding="utf-8") as stream:
            for record in records:
                stream.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
    except OSError as exc:
        fail(f"cannot append per-job result: {exc}")

new_state = {
    "schema_version": 1,
    "job_nonce": nonce,
    "mapping_path": str(mapping_path),
    "transcript_path": str(source),
    "source_device": source_stat.st_dev,
    "source_inode": source_stat.st_ino,
    "source_mtime_ns": source_stat.st_mtime_ns,
    "source_start_offset": start_offset,
    "source_launch_mtime_ns": launch_mtime_ns,
    "source_exists_at_launch": exists_at_launch,
    "source_created_after_launch": created_after_launch,
    "source_size_at_launch": start_offset if exists_at_launch else 0,
    "source_mtime_ns_at_launch": launch_source_mtime if exists_at_launch else None,
    "last_source_offset": complete_end,
    "source_checkpoint": checkpoint(raw, complete_end),
    "executor_session": session or old_session or conversation or old_conversation or "",
    "conversation_id": conversation or old_conversation or "",
    "generation_id": generation or old_generation or "",
    "session_id": session or old_session or "",
    "prompt_echoes": new_echoes,
    "path_captured": True,
    "failure_latched": False,
    "events_seen": nonnegative(state.get("events_seen"), "state.events_seen", 0) + 1,
    "normalized_records": nonnegative(state.get("normalized_records"), "state.normalized_records", 0) + len(records),
    "seen_entries": seen,
}
write_state(new_state)
state = new_state
append_event(str(source), source_stat.st_size, len(records), True)
# Cursor command hooks expect a JSON response.  The shell emits it after
# successful observation; this Python process only owns bridge state.
PY

# A Cursor command hook must always return a valid JSON response on success.
printf '%s\n' '{}'
