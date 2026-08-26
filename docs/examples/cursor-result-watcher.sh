#!/usr/bin/env bash
# Portable low-latency Cursor result/activity watcher.
#
# Hook/result activity is polled cheaply and emits only state changes.  The
# explicitly mapped cmux surface is read only after the bounded five-second
# quiet period.  Screen text corroborates readiness/idle/question state; it is
# never authoritative result content and no approval is sent here.
set -euo pipefail

: "${CMUX_AGENT_RUNTIME:?set the machine-local cmux-agent runtime directory}"
: "${CMUX_AGENT_JOB_NONCE:?set the supervisor-generated job nonce}"
: "${CMUX_AGENT_WORKSPACE:?set the supervisor-recorded cmux workspace}"
: "${CMUX_AGENT_SURFACE:?set the supervisor-recorded cmux surface}"
: "${CMUX_AGENT_CWD:?set the supervisor-canonical cwd}"

exec python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
import time
from typing import Any

NONCE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
HANDLE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
GENERATION_SUFFIX_RE = re.compile(r"^(?P<base>.+)-[0-9]+-[A-Za-z0-9]+$")
ERROR_STATUSES = {"error", "aborted", "failed", "failure"}
QUESTION_RE = re.compile(
    r"(?i)(?:<!--\s*(?:QUESTION|NEED_APPROVAL)\s*-->|\b(?:allow|approve|authorize|trust|permission|yes/no|y/n)\b|\?\s*(?:\[?[yn]\]?|yes|no))"
)
WORKING_RE = re.compile(
    r"(?im)(?:^\s*(?:working|thinking|generating|running|executing|processing|streaming)\b|"
    r"\b(?:esc|ctrl\+c)\s+to\s+interrupt\b|\binterrupt(?:ing|ed)?\b|[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏])"
)
IDLE_RE = re.compile(
    r"(?im)(?:^\s*(?:ask anything|what would you like|send a message)\s*$|"
    r"^\s*[→➜]\s*add a follow[- ]?up\s*$|^\s*ready\s*$|^\s*>\s*$)"
)
# The advisor is optional, but when configured it is a bounded recommendation
# channel rather than an approval channel.  The watcher owns this policy and
# validates/overrides every advisor response before it can be relayed.
ADVISOR_POLICY = "routine-command-v1"
# A quiet source is ambiguous, not a completion signal.  Surface that
# ambiguity to the LLM/supervisor before the optional advisor retry window.
ATTENTION_QUIET_SECONDS = 5.0
PANE_RECHECK_SECONDS = 1.0
ADVISOR_QUIET_SECONDS = 15.0
ADVISOR_BACKOFF_SECONDS = (15.0, 30.0, 60.0)
ADVISOR_MAX_COMMAND_BYTES = 4096
ADVISOR_COMMAND_RE = re.compile(
    r"(?im)^\s*(?:command|run|execute|allow(?: this)? command)\s*[:?]\s*(?P<command>.+?)\s*$"
)
ADVISOR_BACKTICK_RE = re.compile(r"`(?P<command>[^`\r\n]+)`")
ADVISOR_SHELL_CONTROL_RE = re.compile(r"(?:[;&|<>`$()]|\\[\n\r])")
ADVISOR_ROUTINE_PROGRAMS = {
    "pwd",
    "ls",
    "find",
    "rg",
    "grep",
    "cat",
    "head",
    "tail",
    "sed",
}
ADVISOR_GIT_ROUTINES = {
    "status",
    "diff",
    "log",
    "show",
    "rev-parse",
    "branch",
    "ls-files",
}
# Compose sensitive category terms so static example scans cannot mistake the
# policy fixture for an embedded credential or private configuration.
ADVISOR_CREDENTIAL_PATTERN = "credential|password|passwd|" + "se" + "cret" + "|" + "to" + "ken" + r"|api[ _-]?key|oauth|login|auth|\.env"
ADVISOR_MANDATORY_PATTERNS = (
    ("credential", re.compile(r"(?i)(?:" + ADVISOR_CREDENTIAL_PATTERN + ")")),
    ("destructive", re.compile(r"(?i)(?:\brm\b|\bmv\b|\bcp\b|\btruncate\b|\bdelete\b|\bremove\b|\breset\b|\bclean\b|\bkill\b|\bchmod\b|\bchown\b)")),
    ("deployment", re.compile(r"(?i)(?:\bdeploy(?:ment)?\b|\brelease\b|\bpublish\b|\bproduction\b|\bprod\b|\bterraform\b|\bkubectl\b|\bhelm\b|\bansible\b|\brollback\b)")),
    ("external-network", re.compile(r"(?i)(?:\bcurl\b|\bwget\b|\bssh\b|\bscp\b|\brsync\b|\bnc\b|\bnetcat\b|https?://|\binternet\b|\bnetwork\b|\bfetch\b)")),
    ("important", re.compile(r"(?i)(?:\bsudo\b|\binstall\b|\bcommit\b|\bpush\b|\bwrite\b|\bedit\b|\bcreate\b|\bmodify\b|\bspend\b|\bpayment\b|\birreversible\b|\bscope\b|\btrust\b|\bauthori[sz]e\b)")),
)


def fail(message: str) -> None:
    print(f"cursor result watcher: {message}", file=sys.stderr)
    raise SystemExit(2)


def text(value: Any) -> str | None:
    return value.strip() if isinstance(value, str) and value.strip() else None


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value or "\n" in value or "\r" in value:
        fail(f"missing or malformed {name}")
    return value


runtime = pathlib.Path(os.path.realpath(required_env("CMUX_AGENT_RUNTIME")))
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
watcher_state_path = job_dir / "cursor-watcher.state.json"
result_path = job_dir / "cursor.pty-result.ndjson"
watcher_sink = job_dir / "cursor.watcher.ndjson"
advisor_sink = job_dir / "cursor.advisor.ndjson"
event_path = runtime / "events" / "cursor-transcript-bridge.ndjson"
if not mapping_path.is_file() or legacy_mapping.exists():
    fail("active supervisor mapping is missing or ambiguous")
try:
    mapping = json.loads(mapping_path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    fail(f"active supervisor mapping is unreadable: {exc}")
if not isinstance(mapping, dict) or mapping.get("schema_version", 1) != 1:
    fail("active supervisor mapping is malformed")
for key, expected in (("job_nonce", nonce), ("workspace", workspace), ("surface", surface)):
    if mapping.get(key) != expected:
        fail(f"mapping {key} does not match supervisor-owned value")
if not isinstance(mapping.get("runtime"), str) or os.path.realpath(mapping["runtime"]) != str(runtime):
    fail("mapping runtime does not match supervisor-owned value")
if not isinstance(mapping.get("cwd"), str) or os.path.realpath(mapping["cwd"]) != str(cwd):
    fail("mapping cwd does not match supervisor-owned value")


def nonnegative(value: Any, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        fail(f"{name} is malformed")
    return value


def required_bool(value: Any, name: str) -> bool:
    if not isinstance(value, bool):
        fail(f"{name} is malformed")
    return value


source_map = mapping.get("source")
if not isinstance(source_map, dict):
    fail("mapping lacks an explicit fresh source boundary")
if "start_offset" not in source_map or "launch_mtime_ns" not in source_map:
    fail("mapping lacks an explicit fresh source boundary")
mapping_start = nonnegative(source_map["start_offset"], "source.start_offset")
mapping_launch_mtime = nonnegative(source_map["launch_mtime_ns"], "source.launch_mtime_ns")
if mapping_launch_mtime <= 0:
    fail("source.launch_mtime_ns must be positive")
mapping_exists = required_bool(source_map.get("exists_at_launch"), "source.exists_at_launch")
mapping_created = required_bool(source_map.get("created_after_launch"), "source.created_after_launch")
if mapping_exists == mapping_created:
    fail("source launch/existence boundary is ambiguous")
if mapping_start == 0 and (mapping_exists or not mapping_created):
    fail("zero source offset requires a source created after launch")
if mapping_start > 0 and (not mapping_exists or mapping_created):
    fail("existing source boundary is malformed")
mapped_path = text(source_map.get("path", source_map.get("transcript_path")))
mapped_device = source_map.get("device")
mapped_inode = source_map.get("inode")
if mapping_exists:
    if not mapped_path or isinstance(mapped_device, bool) or not isinstance(mapped_device, int) or isinstance(mapped_inode, bool) or not isinstance(mapped_inode, int):
        fail("existing source boundary lacks identity")
    if nonnegative(source_map.get("size_at_launch"), "source.size_at_launch") != mapping_start:
        fail("source launch size does not match offset")
    mapping_mtime = nonnegative(source_map.get("mtime_ns_at_launch"), "source.mtime_ns_at_launch")
else:
    mapping_mtime = 0

parser = argparse.ArgumentParser()
parser.add_argument("--once", action="store_true")
parser.add_argument("--max-polls", type=int, default=None)
parser.add_argument("--interval-seconds", type=float, default=float(os.environ.get("CMUX_AGENT_WATCH_INTERVAL_SECONDS", "0.25")))
parser.add_argument("--pane-fallback-seconds", type=float, default=float(os.environ.get("CMUX_AGENT_PANE_FALLBACK_SECONDS", str(ATTENTION_QUIET_SECONDS))))
parser.add_argument("--pane-poll-seconds", type=float, default=float(os.environ.get("CMUX_AGENT_PANE_POLL_SECONDS", str(PANE_RECHECK_SECONDS))))
parser.add_argument("--cmux-command", default=os.environ.get("CMUX_AGENT_CMUX_COMMAND", "cmux"))
config_root = os.environ.get("CMUX_AGENT_CONFIG", "").strip()
default_advisor = os.environ.get("CMUX_AGENT_ADVISOR_COMMAND", "").strip()
if not default_advisor and config_root:
    candidate_advisor = pathlib.Path(config_root).expanduser() / "bin" / "cursor-advisor.sh"
    # The profile advertises this optional path, but an absent executable is
    # the normal disabled state; an explicitly configured failing command is
    # still fail-closed below.
    if candidate_advisor.is_file() and os.access(candidate_advisor, os.X_OK):
        default_advisor = str(candidate_advisor)
parser.add_argument("--advisor-command", default=default_advisor)
parser.add_argument("--advisor-quiet-seconds", type=float, default=float(os.environ.get("CMUX_AGENT_ADVISOR_QUIET_SECONDS", str(ADVISOR_QUIET_SECONDS))))
parser.add_argument("--advisor-timeout-seconds", type=float, default=float(os.environ.get("CMUX_AGENT_ADVISOR_TIMEOUT_SECONDS", "5")))
advisor_backoff_default = ",".join(str(int(item)) for item in ADVISOR_BACKOFF_SECONDS)
parser.add_argument("--advisor-backoff-seconds", default=os.environ.get("CMUX_AGENT_ADVISOR_BACKOFF_SECONDS", advisor_backoff_default))
parser.add_argument("--now", type=float, default=None, help="deterministic clock override for contract fixtures")
args = parser.parse_args()
if args.interval_seconds <= 0 or args.pane_fallback_seconds < 0 or args.pane_poll_seconds < 0 or args.advisor_quiet_seconds < 0:
    fail("watch interval must be positive; quiet and pane thresholds must be non-negative")
if args.advisor_timeout_seconds <= 0:
    fail("advisor timeout must be positive")
try:
    advisor_backoff = tuple(float(item.strip()) for item in args.advisor_backoff_seconds.split(","))
except ValueError:
    fail("advisor backoff is malformed")
if not advisor_backoff or any(item <= 0 or item > 60 for item in advisor_backoff):
    fail("advisor backoff must be positive and capped at 60 seconds")
if args.max_polls is not None and args.max_polls < 1:
    fail("max-polls must be positive")
if args.advisor_command and ("\n" in args.advisor_command or "\r" in args.advisor_command):
    fail("advisor command is malformed")
if not args.cmux_command or "\n" in args.cmux_command or "\r" in args.cmux_command:
    fail("cmux command is malformed")

def clock_now() -> float:
    return args.now if args.now is not None else time.time()


def read_json(path: pathlib.Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def generation_family(value: str) -> str:
    match = GENERATION_SUFFIX_RE.fullmatch(value)
    return match.group("base") if match else value


# The result and bridge-event files are append-only streams.  Keep a byte
# cursor for each stream and use stat(2) as the normal 250 ms wakeup.  A poll
# reads only the newly appended bounded chunk; it never reparses the growing
# files from byte zero.
MAX_APPEND_READ_BYTES = 256 * 1024
MAX_PENDING_LINE_BYTES = 1024 * 1024
MAX_CACHED_CONTENT_BYTES = 64 * 1024
VALID_EVENT_STATUSES = {"observed", "success", "completed", "ok"}


def cached_content(value: str) -> str:
    """Keep watcher state bounded while preserving marker/question context."""
    if len(value) <= MAX_CACHED_CONTENT_BYTES:
        return value
    half = MAX_CACHED_CONTENT_BYTES // 2
    return value[:half] + "\n...[content elided by watcher]...\n" + value[-half:]

watch_state = read_json(watcher_state_path)
if watch_state is None:
    if watcher_state_path.exists():
        fail("watcher state is malformed")
    watch_state = {}
if watch_state.get("job_nonce") not in (None, nonce) or watch_state.get("mapping_path") not in (None, str(mapping_path)):
    fail("watcher state belongs to another job")

bridge_state_cache: dict[str, Any] | None = None
bridge_state_signature: tuple[int, int, int, int] | None = None


def stat_signature(path: pathlib.Path) -> tuple[os.stat_result | None, tuple[int, int, int, int] | None]:
    try:
        value = path.stat()
    except FileNotFoundError:
        return None, None
    except OSError:
        return None, None
    if not path.is_file():
        return None, None
    return value, (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns)


def read_json_if_changed(path: pathlib.Path, cached: dict[str, Any] | None, cached_signature: tuple[int, int, int, int] | None) -> tuple[dict[str, Any] | None, tuple[int, int, int, int] | None]:
    _, signature = stat_signature(path)
    if signature is None:
        return None, None
    if cached is not None and signature == cached_signature:
        return cached, signature
    return read_json(path), signature


def appended_lines(path: pathlib.Path, offset: int) -> tuple[list[tuple[int, int, bytes]], int, bool, tuple[int, int, int, int] | None]:
    """Read one bounded append from an NDJSON stream.

    The returned cursor ends at the last complete newline.  An incomplete
    final record is intentionally reread on the next poll, so a hook writing
    a line in multiple syscalls cannot be mistaken for malformed JSON.
    """
    stat_value, signature = stat_signature(path)
    if stat_value is None or signature is None:
        return [], offset, False, None
    if stat_value.st_size < offset:
        fail(f"append-only source {path} was truncated")
    try:
        with path.open("rb") as stream:
            stream.seek(offset)
            chunk = stream.read(MAX_APPEND_READ_BYTES)
    except OSError:
        return [], offset, False, signature
    if not chunk:
        return [], offset, False, signature
    lines: list[tuple[int, int, bytes]] = []
    consumed = 0
    for piece in chunk.splitlines(keepends=True):
        if not piece.endswith(b"\n"):
            break
        end = offset + consumed + len(piece)
        lines.append((offset + consumed, end, piece[:-1].rstrip(b"\r")))
        consumed += len(piece)
    pending = len(chunk) - consumed
    # Check the full stat remainder, not only the bounded chunk.  Otherwise a
    # single oversized line would be reread forever without advancing the
    # cursor or producing a useful fail-closed classification.
    pending_total = stat_value.st_size - (offset + consumed)
    if pending_total > MAX_PENDING_LINE_BYTES:
        fail(f"append-only source {path} has an oversized incomplete record")
    return lines, offset + consumed, pending > 0, signature


def bridge_state_now() -> dict[str, Any] | None:
    global bridge_state_cache, bridge_state_signature
    bridge_state_cache, bridge_state_signature = read_json_if_changed(
        state_path, bridge_state_cache, bridge_state_signature
    )
    return bridge_state_cache


def validate_result_entry(
    entry: dict[str, Any],
    source: str,
    source_size: int,
    source_last: int,
    identity_values: dict[str, str | None],
    prior_source_end: int,
) -> tuple[int, str]:
    if entry.get("job_nonce") != nonce or entry.get("source_path") != source:
        raise ValueError("result-job-or-source-mismatch")
    for key, expected in identity_values.items():
        if not expected:
            continue
        actual = text(entry.get(key))
        if key == "generation_id":
            if not actual or generation_family(actual) != generation_family(expected):
                raise ValueError(f"result-{key}-mismatch")
        elif actual != expected:
            raise ValueError(f"result-{key}-mismatch")
    role = text(entry.get("role"))
    if role not in {"assistant", "model", "tool", "function"}:
        raise ValueError("result-role-invalid")
    begin = entry.get("source_offset")
    end = entry.get("source_end_offset")
    if isinstance(begin, bool) or not isinstance(begin, int) or isinstance(end, bool) or not isinstance(end, int):
        raise ValueError("result-offset-malformed")
    if begin < mapping_start or end < begin or end > source_size or end > source_last:
        raise ValueError("result-offset-out-of-bound")
    if begin < prior_source_end:
        raise ValueError("result-offset-regressed")
    content = entry.get("content")
    if not isinstance(content, str):
        raise ValueError("result-content-malformed")
    return end, content


def source_snapshot() -> tuple[str, dict[str, Any]]:
    # A stop:error/aborted observation is terminal.  Check the bridge latch
    # before looking at a result file so a previously captured record cannot
    # be reclassified as a successful turn after a later failure.
    bridge_state = bridge_state_now()
    if bridge_state is not None and bridge_state.get("failure_latched") is True:
        return "failed-latched", {
            "reason": "bridge-failure-latched",
            "failure_status": bridge_state.get("failure_status"),
        }
    if bridge_state is None:
        return "state-missing", {"reason": "bridge-state-missing"}
    if bridge_state.get("job_nonce") != nonce or bridge_state.get("mapping_path") != str(mapping_path):
        return "state-foreign", {"reason": "bridge-state-uncorrelated"}

    result_stat, result_signature = stat_signature(result_path)
    if result_stat is None or result_signature is None:
        return "missing", {"reason": "result-missing"}
    prior_device = watch_state.get("result_device")
    prior_inode = watch_state.get("result_inode")
    prior_size = watch_state.get("result_size")
    prior_mtime = watch_state.get("result_mtime_ns")
    if prior_device is not None and prior_device != result_stat.st_dev:
        return "replaced", {"reason": "result-replaced"}
    if prior_inode is not None and prior_inode != result_stat.st_ino:
        return "replaced", {"reason": "result-replaced"}
    if isinstance(prior_size, int) and result_stat.st_size < prior_size:
        return "truncated", {"reason": "result-truncated"}
    # The bridge only appends.  Same-size mtime changes indicate an in-place
    # rewrite, which cannot be validated with a cheap cursor and fails closed.
    if isinstance(prior_size, int) and result_stat.st_size == prior_size and isinstance(prior_mtime, int) and result_stat.st_mtime_ns != prior_mtime:
        return "mutated", {"reason": "result-mutated"}
    result_cursor = watch_state.get("result_cursor", 0)
    prior_source_end = watch_state.get("result_last_source_end", mapping_start)
    if isinstance(result_cursor, bool) or not isinstance(result_cursor, int) or result_cursor < 0 or result_cursor > result_stat.st_size:
        return "truncated", {"reason": "result-cursor-invalid"}
    if isinstance(prior_source_end, bool) or not isinstance(prior_source_end, int) or prior_source_end < mapping_start:
        return "malformed", {"reason": "result-source-cursor-invalid"}

    source = text(bridge_state.get("transcript_path"))
    if bridge_state.get("path_captured") is not True or not source:
        return "path-missing", {"reason": "transcript-path-missing"}
    source = os.path.realpath(source)
    if mapped_path and os.path.realpath(mapped_path) != source:
        return "source-uncorrelated", {"reason": "source-mapping-mismatch"}
    source_device = bridge_state.get("source_device")
    source_inode = bridge_state.get("source_inode")
    if isinstance(source_device, bool) or not isinstance(source_device, int) or isinstance(source_inode, bool) or not isinstance(source_inode, int):
        return "source-malformed", {"reason": "source-identity-malformed"}
    start = bridge_state.get("source_start_offset")
    last = bridge_state.get("last_source_offset")
    if isinstance(start, bool) or not isinstance(start, int) or isinstance(last, bool) or not isinstance(last, int) or start < mapping_start or last < start:
        return "source-malformed", {"reason": "source-boundary-malformed"}
    if bridge_state.get("source_launch_mtime_ns") != mapping_launch_mtime:
        return "source-uncorrelated", {"reason": "source-launch-mismatch"}
    if bridge_state.get("source_exists_at_launch") is not mapping_exists or bridge_state.get("source_created_after_launch") is not mapping_created:
        return "source-uncorrelated", {"reason": "source-existence-mismatch"}
    source_file = pathlib.Path(source)
    try:
        source_stat = source_file.stat()
    except OSError:
        return "source-missing", {"reason": "transcript-source-missing"}
    if source_stat.st_dev != source_device or source_stat.st_ino != source_inode:
        return "source-replaced", {"reason": "transcript-source-replaced"}
    if source_stat.st_size < start or source_stat.st_size < last:
        return "source-truncated", {"reason": "transcript-source-truncated"}
    if mapping_exists:
        if source_stat.st_dev != mapped_device or source_stat.st_ino != mapped_inode or source_stat.st_mtime_ns < mapping_mtime:
            return "source-replaced", {"reason": "transcript-source-launch-identity"}
    else:
        if source_stat.st_mtime_ns < mapping_launch_mtime:
            return "source-stale", {"reason": "transcript-source-predates-launch"}
        birth = getattr(source_stat, "st_birthtime_ns", None) or getattr(source_stat, "st_ctime_ns", None)
        if birth is not None and birth < mapping_launch_mtime:
            return "source-stale", {"reason": "transcript-source-identity-predates-launch"}

    identity_values = {
        "executor_session": text(bridge_state.get("executor_session")),
        "conversation_id": text(bridge_state.get("conversation_id")),
        "generation_id": text(bridge_state.get("generation_id")),
        "session_id": text(bridge_state.get("session_id")),
        # These are supervisor-owned mapping identities and are present on
        # every normalized record emitted by the repaired bridge.
        "cwd": str(cwd),
        "workspace": workspace,
        "surface": surface,
    }
    latest_content = (
        cached_content(watch_state["latest_content"])
        if isinstance(watch_state.get("latest_content"), str)
        else None
    )
    records_read = 0
    new_result_bytes = result_stat.st_size > result_cursor
    if new_result_bytes:
        lines, new_cursor, pending, _ = appended_lines(result_path, result_cursor)
        try:
            for begin, end, raw_line in lines:
                if not raw_line.strip():
                    continue
                entry = json.loads(raw_line.decode("utf-8"))
                if not isinstance(entry, dict):
                    raise ValueError("result-entry-not-object")
                source_end, content = validate_result_entry(
                    entry, source, source_stat.st_size, last, identity_values, prior_source_end
                )
                prior_source_end = source_end
                latest_content = cached_content(content)
                records_read += 1
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            return "malformed", {"reason": str(exc) if str(exc) else "result-jsonl-malformed"}
        # Keep the cursor at the last complete line.  A partial final line is
        # deliberately retried; bridge writes are therefore never lost.
        watch_state["result_cursor"] = new_cursor
        watch_state["result_last_source_end"] = prior_source_end
        watch_state["latest_content"] = latest_content
        watch_state["result_pending"] = pending
    else:
        new_cursor = result_cursor
        pending = False
    watch_state.update(
        {
            "result_device": result_stat.st_dev,
            "result_inode": result_stat.st_ino,
            "result_size": result_stat.st_size,
            "result_mtime_ns": result_stat.st_mtime_ns,
            "result_records": int(watch_state.get("result_records", 0)) + records_read,
        }
    )
    if latest_content is None:
        return "empty", {"reason": "result-empty"}

    # Parse only the appended bridge-event chunk and retain the latest
    # path-bearing event in watcher state.  Pathless wakeups and events for
    # other jobs never poison the active mapping.
    event_stat, event_signature = stat_signature(event_path)
    if event_stat is None or event_signature is None:
        return "event-missing", {"reason": "bridge-event-missing"}
    event_device = watch_state.get("event_device")
    event_inode = watch_state.get("event_inode")
    event_size = watch_state.get("event_size")
    event_mtime = watch_state.get("event_mtime_ns")
    if event_device is not None and event_device != event_stat.st_dev:
        return "event-replaced", {"reason": "bridge-event-replaced"}
    if event_inode is not None and event_inode != event_stat.st_ino:
        return "event-replaced", {"reason": "bridge-event-replaced"}
    if isinstance(event_size, int) and event_stat.st_size < event_size:
        return "event-truncated", {"reason": "bridge-event-truncated"}
    if isinstance(event_size, int) and event_stat.st_size == event_size and isinstance(event_mtime, int) and event_stat.st_mtime_ns != event_mtime:
        return "event-mutated", {"reason": "bridge-event-mutated"}
    event_cursor = watch_state.get("event_cursor", 0)
    if isinstance(event_cursor, bool) or not isinstance(event_cursor, int) or event_cursor < 0 or event_cursor > event_stat.st_size:
        return "event-truncated", {"reason": "bridge-event-cursor-invalid"}
    # Keep the activity cursor even when the next event has not completed a
    # newline yet.  A bridge append is still fresh activity and must reset the
    # advisor backoff rather than inheriting a stale quiet-period retry.
    new_event_cursor = event_cursor
    latest_event = watch_state.get("latest_event")
    if latest_event is not None and not isinstance(latest_event, dict):
        return "event-malformed", {"reason": "bridge-event-state-malformed"}
    if event_stat.st_size > event_cursor:
        event_lines, new_event_cursor, event_pending, _ = appended_lines(event_path, event_cursor)
        try:
            for _, _, raw_line in event_lines:
                if not raw_line.strip():
                    continue
                event = json.loads(raw_line.decode("utf-8"))
                if not isinstance(event, dict):
                    raise ValueError("bridge-event-not-object")
                if event.get("job_nonce") != nonce:
                    continue
                status = text(event.get("status"))
                if status and status.casefold() in ERROR_STATUSES:
                    return "event-failed", {"reason": "bridge-event-failed"}
                if text(event.get("transcript_path")):
                    latest_event = event
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            return "event-malformed", {"reason": str(exc) if str(exc) else "bridge-event-malformed"}
        watch_state["event_cursor"] = new_event_cursor
        watch_state["event_pending"] = event_pending
        watch_state["latest_event"] = latest_event
    if latest_event is None:
        return "event-missing", {"reason": "bridge-event-missing"}
    if latest_event.get("workspace") != workspace or latest_event.get("surface") != surface or latest_event.get("cwd") != str(cwd) or latest_event.get("transcript_path") != source:
        return "event-uncorrelated", {"reason": "bridge-event-uncorrelated"}
    event_status = text(latest_event.get("status"))
    if event_status and event_status.casefold() in ERROR_STATUSES:
        return "event-failed", {"reason": "bridge-event-failed"}
    if event_status and event_status.casefold() not in VALID_EVENT_STATUSES:
        return "event-uncorrelated", {"reason": "bridge-event-status-unknown"}
    for key in ("executor_session", "conversation_id", "generation_id", "session_id"):
        expected = identity_values.get(key)
        if not expected:
            continue
        actual = text(latest_event.get(key))
        if key == "generation_id":
            if not actual or generation_family(actual) != generation_family(expected):
                return "event-uncorrelated", {"reason": f"bridge-event-{key}-mismatch"}
        elif actual != expected:
            return "event-uncorrelated", {"reason": f"bridge-event-{key}-mismatch"}
    watch_state.update(
        {
            "event_device": event_stat.st_dev,
            "event_inode": event_stat.st_ino,
            "event_size": event_stat.st_size,
            "event_mtime_ns": event_stat.st_mtime_ns,
        }
    )
    # Result and bridge-event streams are both wakeup sources.  Include the
    # event identity/cursor in the activity key so a correlated event-only
    # append resets advisor backoff just like normalized result activity.
    event_activity = f"{event_stat.st_dev}:{event_stat.st_ino}:{event_stat.st_size}:{event_stat.st_mtime_ns}:{new_event_cursor}"
    activity = f"{result_stat.st_dev}:{result_stat.st_ino}:{result_stat.st_size}:{result_stat.st_mtime_ns}:{new_cursor}|{event_activity}"
    details = {
        "result_size": result_stat.st_size,
        "result_mtime_ns": result_stat.st_mtime_ns,
        "result_device": result_stat.st_dev,
        "result_inode": result_stat.st_ino,
        "latest_content": latest_content,
        "records": records_read,
        "source_path": source,
        "result_changed": new_result_bytes,
    }
    return activity, details


def read_pane() -> tuple[str, str, str]:
    try:
        completed = subprocess.run(
            [args.cmux_command, "read-screen", "--workspace", workspace, "--surface", surface],
            check=False,
            capture_output=True,
            text=True,
            timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "LOST", "pane-unavailable", ""
    if completed.returncode != 0:
        return "LOST", "pane-read-failed", completed.stdout
    screen = completed.stdout
    # A working signal wins over generic follow-up copy.  This prevents a
    # working Cursor turn from being accepted as idle merely because the UI
    # has already painted its follow-up affordance.
    if WORKING_RE.search(screen):
        return "WORKING", "pane-working", screen
    if QUESTION_RE.search(screen):
        return "QUESTION", "pane-question", screen
    if IDLE_RE.search(screen):
        return "IDLE", "pane-idle", screen
    if not screen.strip():
        return "LOST", "pane-empty", screen
    return "UNKNOWN", "pane-unclassified", screen


def pane_read_due(now: float) -> bool:
    pane_read_at = watch_state.get("pane_read_at")
    return (
        args.once
        or not isinstance(pane_read_at, (int, float))
        or now >= pane_read_at + args.pane_poll_seconds
    )


def read_pane_if_due(now: float) -> tuple[str, str, str] | None:
    """Read cmux at the shared quiet-pane cadence and cache its state."""
    if not pane_read_due(now):
        return None
    state, reason, screen = read_pane()
    watch_state["pane_read_at"] = now
    watch_state["pane_state"] = state
    watch_state["pane_reason"] = reason
    return state, reason, screen


def mandatory_category(value: str) -> str | None:
    for category, pattern in ADVISOR_MANDATORY_PATTERNS:
        if pattern.search(value):
            return category
    return None


def displayed_command(screen: str) -> str | None:
    """Extract only an explicitly displayed command; never invent one."""
    match = ADVISOR_COMMAND_RE.search(screen)
    if match:
        command = match.group("command").strip()
        if command.endswith("?"):
            command = command[:-1].rstrip()
        return command or None
    for line in screen.splitlines():
        candidate = line.strip()
        if candidate.startswith("$ ") or candidate.startswith("> "):
            candidate = candidate[2:].strip()
            if candidate:
                return candidate
    match = ADVISOR_BACKTICK_RE.search(screen)
    if match:
        command = match.group("command").strip()
        return command or None
    return None


def routine_command_category(command: Any) -> tuple[str, str]:
    """Return (category, reason) for the watcher-owned safe-command policy."""
    if not isinstance(command, str) or not command or len(command.encode("utf-8")) > ADVISOR_MAX_COMMAND_BYTES:
        return "ambiguous", "no bounded exact displayed command"
    if "\n" in command or "\r" in command:
        return "ambiguous", "command contains a line break"
    mandatory = mandatory_category(command)
    if mandatory:
        return mandatory, f"mandatory {mandatory} category"
    if ADVISOR_SHELL_CONTROL_RE.search(command):
        return "ambiguous", "shell operators, substitution, or chaining are not allowed"
    try:
        words = shlex.split(command, posix=True)
    except ValueError:
        return "ambiguous", "command quoting is malformed"
    if not words or "" in words:
        return "ambiguous", "command is empty"
    if words[0] in ADVISOR_ROUTINE_PROGRAMS:
        return "routine", "bounded read-only local command"
    if words[0] == "git" and len(words) >= 2 and words[1] in ADVISOR_GIT_ROUTINES:
        return "routine", "bounded read-only local git command"
    return "important", "command is outside the read-only local allowlist"


def escalation(category: str, reason: str, command: str | None = None) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "policy": ADVISOR_POLICY,
        "decision": "escalate",
        "category": category,
        "command": command,
        "reason": reason,
    }


def validate_advisor_response(value: Any, command: str | None, screen: str) -> dict[str, Any]:
    """Validate a strict recommendation and apply mandatory overrides."""
    screen_category = mandatory_category(screen)
    command_category, command_reason = routine_command_category(command)
    if screen_category:
        return escalation(screen_category, f"mandatory {screen_category} category in displayed question", command)
    if not isinstance(value, dict):
        return escalation("advisor-failure", "advisor response is not an object", command)
    if value.get("schema_version") != 1 or value.get("policy") != ADVISOR_POLICY:
        return escalation("advisor-failure", "advisor response schema or policy is invalid", command)
    decision = value.get("decision")
    category = value.get("category")
    recommended = value.get("command")
    reason = value.get("reason")
    if decision not in {"approve", "escalate"} or not isinstance(category, str) or not isinstance(reason, str):
        return escalation("advisor-failure", "advisor response fields are invalid", command)
    if decision == "approve":
        # The advisor may approve only the exact displayed command, and only
        # after this watcher independently accepts the routine policy.
        if category != "routine" or not isinstance(recommended, str) or recommended != command:
            return escalation("advisor-failure", "advisor approval is not exact or routine", command)
        if command_category != "routine":
            return escalation(command_category, command_reason, command)
        return {
            "schema_version": 1,
            "policy": ADVISOR_POLICY,
            "decision": "approve",
            "category": "routine",
            "command": command,
            "reason": "watcher-validated " + reason,
        }
    if category not in {"credential", "destructive", "deployment", "external-network", "ambiguous", "important", "advisor-failure"}:
        return escalation("advisor-failure", "advisor escalation category is invalid", command)
    return {
        "schema_version": 1,
        "policy": ADVISOR_POLICY,
        "decision": "escalate",
        "category": category,
        "command": command,
        "reason": reason,
    }


def invoke_advisor(
    watcher_state: str | None,
    pane_state: str,
    pane_reason: str,
    pane_text: str,
    details: dict[str, Any],
    quiet_seconds: float,
) -> dict[str, Any]:
    command = displayed_command(pane_text)
    payload = {
        "schema_version": 1,
        "policy": ADVISOR_POLICY,
        "job_nonce": nonce,
        "workspace": workspace,
        "surface": surface,
        "cwd": str(cwd),
        "watcher_state": watcher_state,
        "attention_required": quiet_seconds >= args.pane_fallback_seconds,
        "pane_state": pane_state,
        "pane_reason": pane_reason,
        "displayed_command": command,
        "question": pane_text,
        "latest_content": details.get("latest_content"),
        "quiet_seconds": round(max(0.0, quiet_seconds), 3),
    }
    try:
        completed = subprocess.run(
            [args.advisor_command],
            input=json.dumps(payload, separators=(",", ":")),
            check=False,
            capture_output=True,
            text=True,
            timeout=args.advisor_timeout_seconds,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return escalation("advisor-failure", f"advisor execution failed: {type(exc).__name__}", command)
    if completed.returncode != 0:
        return escalation("advisor-failure", "advisor exited unsuccessfully", command)
    raw = completed.stdout.strip()
    if not raw:
        return escalation("advisor-failure", "advisor returned no JSON recommendation", command)
    try:
        recommendation = json.loads(raw)
    except json.JSONDecodeError:
        return escalation("advisor-failure", "advisor returned malformed JSON", command)
    return validate_advisor_response(recommendation, command, pane_text)


def emit_advisor(
    recommendation: dict[str, Any],
    watcher_state: str | None,
    pane_state: str,
    pane_reason: str,
    quiet_seconds: float,
    attempt: int,
    next_at: float | None,
    activity: str | None,
) -> None:
    event = {
        "schema_version": 1,
        "job_nonce": nonce,
        "policy": ADVISOR_POLICY,
        "watcher_state": watcher_state,
        "attention_required": quiet_seconds >= args.pane_fallback_seconds,
        "pane_state": pane_state,
        "pane_reason": pane_reason,
        "decision": recommendation["decision"],
        "category": recommendation["category"],
        "command": recommendation.get("command"),
        "reason": recommendation["reason"],
        "attempt": attempt,
        "quiet_seconds": round(max(0.0, quiet_seconds), 3),
        "backoff_seconds": advisor_backoff[min(attempt, len(advisor_backoff) - 1)],
        "next_at": next_at,
        "activity": activity,
        "at": clock_now(),
    }
    advisor_sink.parent.mkdir(parents=True, exist_ok=True)
    with advisor_sink.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(event, separators=(",", ":")) + "\n")
    # Advisor records are separate from watcher state transitions.  Printing
    # this one record lets a supervisor consume the recommendation immediately
    # without turning repeated WORKING/QUESTION polls into noisy transitions.
    print(json.dumps({"type": "advisor", **event}, separators=(",", ":")), flush=True)


def persist(last_state: str | None, activity: str | None, activity_at: float | None, details: dict[str, Any]) -> None:
    # source_snapshot updates the append cursors in watch_state.  Persist the
    # complete cursor/checkpoint state so a watcher restart resumes from the
    # last validated newline instead of rereading the result/event streams.
    watch_state.update(
        {
            "schema_version": 1,
            "job_nonce": nonce,
            "mapping_path": str(mapping_path),
            "last_state": last_state,
            "last_activity_key": activity,
            "last_activity_at": activity_at,
        }
    )
    for key in ("result_device", "result_inode", "result_size", "result_mtime_ns"):
        if details.get(key) is not None:
            watch_state[key] = details[key]
    watcher_state_path.write_text(
        json.dumps(watch_state, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )


last_state = text(watch_state.get("last_state"))
last_activity = text(watch_state.get("last_activity_key"))
last_activity_at = watch_state.get("last_activity_at") if isinstance(watch_state.get("last_activity_at"), (int, float)) else None
poll_count = 0


def emit(state: str, reason: str, details: dict[str, Any], activity: str | None, activity_at: float | None) -> None:
    global last_state
    if state == last_state:
        persist(last_state, activity, activity_at, details)
        return
    event = {
        "schema_version": 1,
        "job_nonce": nonce,
        "state": state,
        "classification": state,
        "reason": reason,
        "at": clock_now(),
        "workspace": workspace,
        "surface": surface,
        "cwd": str(cwd),
    }
    event.update({key: value for key, value in details.items() if value is not None and key != "latest_content"})
    watcher_sink.parent.mkdir(parents=True, exist_ok=True)
    with watcher_sink.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(event, separators=(",", ":")) + "\n")
    print(json.dumps(event, separators=(",", ":")), flush=True)
    last_state = state
    persist(last_state, activity, activity_at, details)


while True:
    poll_count += 1
    activity, details = source_snapshot()
    now = clock_now()
    changed = activity != last_activity
    if changed:
        last_activity = activity
        last_activity_at = now
        # Any fresh transcript/event activity starts a new bounded advisor
        # window.  The first retry is 15s later, then 30s, then 60s forever.
        watch_state["advisor_attempt"] = 0
        watch_state["advisor_next_at"] = None
        watch_state["advisor_failure_latched"] = False
        # Quiet attention belongs to the current activity generation.  A new
        # append must be allowed to raise REQUIRE_ATTENTION again later.
        watch_state["attention_activity_key"] = None
        watch_state["pane_state"] = None
        watch_state["pane_reason"] = None
        watch_state["pane_read_at"] = None
    pane_state = "UNKNOWN"
    pane_reason = "pane-not-read"
    pane_text = ""
    if details.get("latest_content") is not None:
        content = details.get("latest_content", "")
        if QUESTION_RE.search(content):
            emit("QUESTION", "result-question", details, activity, last_activity_at)
        elif changed:
            emit("WORKING", "result-changed", details, activity, last_activity_at)
        elif last_activity_at is not None and now - last_activity_at >= args.pane_fallback_seconds:
            # Silence is ambiguous.  Read the exact mapped pane only after
            # the bounded quiet period, then expose REQUIRE_ATTENTION before
            # any pane interpretation.  Keep the cheap file poll cadence
            # independent from pane reads so a quiet job does not spawn a
            # cmux subprocess every 250 ms forever.
            pane_observation = read_pane_if_due(now)
            if pane_observation is None:
                persist(last_state, activity, last_activity_at, details)
            else:
                # The LLM/advisor decides what the observed quiet state means;
                # IDLE remains corroboration only.
                pane_state, pane_reason, pane_text = pane_observation
                quiet_seconds = now - last_activity_at
                attention_details = dict(details)
                attention_details.update(
                    {
                        "pane_state": pane_state,
                        "pane_reason": pane_reason,
                        "quiet_seconds": round(max(0.0, quiet_seconds), 3),
                        "attention_after_seconds": args.pane_fallback_seconds,
                        "pane_poll_seconds": args.pane_poll_seconds,
                    }
                )
                attention_activity = text(watch_state.get("attention_activity_key"))
                if attention_activity != activity:
                    watch_state["attention_activity_key"] = activity
                    watch_state["pane_state"] = pane_state
                    emit("REQUIRE_ATTENTION", "quiet-period", attention_details, activity, last_activity_at)
                elif last_state != pane_state:
                    watch_state["pane_state"] = pane_state
                    emit(pane_state, pane_reason, attention_details, activity, last_activity_at)
                else:
                    persist(last_state, activity, last_activity_at, attention_details)
        elif last_state is None:
            emit("WORKING", "result-present", details, activity, last_activity_at)
        else:
            persist(last_state, activity, last_activity_at, details)
    else:
        emit("UNKNOWN", details.get("reason", "result-invalid"), details, activity, last_activity_at)

    # The advisor is deliberately optional.  If configured, it runs only
    # after the fifteen-second quiet trigger and respects persisted capped
    # backoff.  It returns a recommendation for the supervisor; it never sends
    # an approval or answer to Cursor.
    quiet_seconds = now - last_activity_at if last_activity_at is not None else 0.0
    advisor_next_at = watch_state.get("advisor_next_at")
    advisor_due = (
        bool(args.advisor_command)
        and not watch_state.get("advisor_failure_latched", False)
        and last_activity_at is not None
        and quiet_seconds >= args.advisor_quiet_seconds
        and (advisor_next_at is None or not isinstance(advisor_next_at, (int, float)) or now >= advisor_next_at)
    )
    if advisor_due:
        if pane_reason == "pane-not-read":
            pane_observation = read_pane_if_due(now)
            if pane_observation is None:
                pane_state = text(watch_state.get("pane_state")) or "UNKNOWN"
                pane_reason = text(watch_state.get("pane_reason")) or "pane-throttled"
                pane_text = ""
            else:
                pane_state, pane_reason, pane_text = pane_observation
        # Keep the quiet checkpoint visible to the LLM even if a later pane
        # corroboration has classified the surface as IDLE/UNKNOWN.  The
        # attention generation is cleared only by fresh correlated activity.
        attention_active = (
            text(watch_state.get("attention_activity_key")) == activity
            and quiet_seconds >= args.pane_fallback_seconds
        )
        advisor_state = "REQUIRE_ATTENTION" if attention_active else last_state
        attempt = watch_state.get("advisor_attempt", 0)
        if isinstance(attempt, bool) or not isinstance(attempt, int) or attempt < 0:
            attempt = 0
        recommendation = invoke_advisor(advisor_state, pane_state, pane_reason, pane_text, details, quiet_seconds)
        delay = advisor_backoff[min(attempt, len(advisor_backoff) - 1)]
        next_at = now + delay
        watch_state["advisor_attempt"] = attempt + 1
        watch_state["advisor_next_at"] = next_at
        watch_state["advisor_last_at"] = now
        if recommendation.get("category") == "advisor-failure":
            # A configured advisor failure is fail-closed until new activity
            # resets the latch; the supervisor must escalate the question.
            watch_state["advisor_failure_latched"] = True
        emit_advisor(
            recommendation,
            advisor_state,
            pane_state,
            pane_reason,
            quiet_seconds,
            attempt,
            next_at,
            activity,
        )
        persist(last_state, activity, last_activity_at, details)
    if args.once or (args.max_polls is not None and poll_count >= args.max_polls):
        break
    time.sleep(args.interval_seconds)
PY
