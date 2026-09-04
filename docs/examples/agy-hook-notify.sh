#!/usr/bin/env bash
# agy-hook-notify.sh - portable agy `PostInvocation` lifecycle hook.
# Copy to the machine-local path `~/bin/agy-hook-notify.sh` and review before use.
#
# Target product: the Antigravity-family `agy` CLI (observed as `agy 1.1.13`),
# which registers named hooks in `~/.gemini/config/hooks.json` and delivers
# camelCase JSON payloads on stdin (for example `transcriptPath`,
# `conversationId`, `invocationNum`) expecting a JSON object back on stdout.
#
# This adapter only:
#   1. validates the `PostInvocation` payload and the supervisor-owned job map;
#   2. accepts exactly the configured transcript source, never an arbitrary
#      hook-supplied path;
#   3. reads only complete transcript records appended after the persisted
#      launch boundary (and the adapter's persisted source cursor);
#   4. stages normalized model output and at most one correlated lifecycle
#      event per invocation identity, committing both to their sinks together;
#      and
#   5. returns an empty JSON object, which the agy hook stdout contract requires.
#
# The supervisor must create `jobs/<job_nonce>/agy.mapping.json` before launch,
# record both source and result boundaries there, and export
# `CMUX_AGENT_JOB_RUNTIME` and `CMUX_AGENT_JOB_NONCE` to the hook. Missing,
# malformed, stale, replaced, truncated, or uncorrelated sources fail closed.
#
# `status: success` means only that this `PostInvocation` callback ran and
# captured a bounded fresh source segment. It never proves task correctness;
# the supervisor still requires the correlated nonce-framed marker, artifact and
# focused checks, and idle cmux corroboration before accepting completion.
#
# It never approves tools, edits files on the operator's behalf, or grants
# permission. No private path is hard-coded here.
set -euo pipefail

runtime_env="${CMUX_AGENT_JOB_RUNTIME:?set the supervisor-generated per-job runtime directory}"
job_nonce="${CMUX_AGENT_JOB_NONCE:?set the supervisor-generated job nonce}"
result_file="${HOME}/agi-result.txt"
sink="${runtime_env}/events/agy-result.ndjson"
# Bound hook input before handing it to Python.  A hook payload is metadata,
# not a transcript transport, so rejecting an oversized payload is safer than
# allowing command-substitution or argv memory to grow without a limit.
MAX_HOOK_PAYLOAD_BYTES=65536
payload_file=$(mktemp "${TMPDIR:-/tmp}/cmux-agy-hook-payload.XXXXXX")
trap 'rm -f -- "$payload_file"' EXIT
if ! head -c "$((MAX_HOOK_PAYLOAD_BYTES + 1))" >"$payload_file"; then
  echo 'agy hook: cannot read bounded hook payload' >&2
  exit 2
fi
if [[ "$(wc -c <"$payload_file" | tr -d '[:space:]')" -gt "$MAX_HOOK_PAYLOAD_BYTES" ]]; then
  echo 'agy hook: hook payload is too large' >&2
  exit 2
fi

# Keep all validation, source reading, and writes under one lock. The payload
# path is bounded and passed as an argument only after the hook has consumed
# stdin; the payload itself is never interpolated into shell code.
python3 - "$payload_file" "$runtime_env" "$job_nonce" "$result_file" "$sink" <<'PY'
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import pathlib
import re
import sys
import tempfile
from typing import Any

payload_path, runtime_raw, nonce, result_raw, sink_raw = sys.argv[1:]
HANDLE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
MAX_TEXT_BYTES = 512
MAX_INT = 2**63 - 1
MAX_HOOK_PAYLOAD_BYTES = 65536
MAX_METADATA_BYTES = 65536
# A callback is intentionally finite: it may consume only one bounded fresh
# source segment, bounded complete records, and bounded normalized output.  The
# cursor lets later callbacks continue without putting the whole transcript in
# memory or silently truncating a record.
MAX_TRANSCRIPT_DELTA_BYTES = 4 * 1024 * 1024
MAX_TRANSCRIPT_RECORD_BYTES = 256 * 1024
MAX_TRANSCRIPT_RECORDS = 8192
MAX_NORMALIZED_OUTPUT_BYTES = 4 * 1024 * 1024
IO_CHUNK_BYTES = 1024 * 1024


def fail(message: str) -> None:
    print(f"agy hook: {message}", file=sys.stderr)
    raise SystemExit(2)


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON object key: {key}")
        result[key] = value
    return result


def load_json(path: pathlib.Path, label: str) -> Any:
    try:
        raw = path.read_bytes()
        if len(raw) > MAX_METADATA_BYTES:
            fail(f"{label} is too large")
        return json.loads(raw.decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
        fail(f"{label} is malformed or unreadable: {exc}")


def bounded_text(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(f"{label} must be a non-empty string")
    value = value.strip()
    if any(ord(char) < 0x20 or ord(char) == 0x7F for char in value):
        fail(f"{label} contains control characters")
    try:
        if len(value.encode("utf-8")) > MAX_TEXT_BYTES:
            fail(f"{label} is too long")
    except UnicodeEncodeError as exc:
        fail(f"{label} is not valid UTF-8: {exc}")
    return value


def canonical_path(value: Any, label: str) -> str:
    value = bounded_text(value, label)
    if not os.path.isabs(value):
        fail(f"{label} must be absolute")
    return os.path.realpath(value)


def nonnegative(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0 or value > MAX_INT:
        fail(f"{label} must be a bounded non-negative integer")
    return value


def positive(value: Any, label: str) -> int:
    value = nonnegative(value, label)
    if value == 0:
        fail(f"{label} must be positive")
    return value


def required_bool(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        fail(f"{label} must be an explicit boolean")
    return value


def map_path(value: dict[str, Any], label: str) -> str:
    candidates = [value[key] for key in ("path", "transcript_path") if key in value]
    if not candidates:
        fail(f"{label} lacks a configured path")
    paths = [canonical_path(candidate, f"{label}.path") for candidate in candidates]
    if len(set(paths)) != 1:
        fail(f"{label} has conflicting paths")
    return paths[0]


def parse_boundary(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} boundary is missing or malformed")
    start = nonnegative(value.get("start_offset"), f"{label}.start_offset")
    launch_mtime = positive(value.get("launch_mtime_ns"), f"{label}.launch_mtime_ns")
    exists = required_bool(value.get("exists_at_launch"), f"{label}.exists_at_launch")
    created = required_bool(value.get("created_after_launch"), f"{label}.created_after_launch")
    if exists == created:
        fail(f"{label} launch/existence boundary is ambiguous")
    parsed: dict[str, Any] = {
        "start_offset": start,
        "launch_mtime_ns": launch_mtime,
        "exists_at_launch": exists,
        "created_after_launch": created,
    }
    if exists:
        for key in ("device", "inode", "size_at_launch"):
            parsed[key] = nonnegative(value.get(key), f"{label}.{key}")
        if parsed["size_at_launch"] != start:
            fail(f"{label}.size_at_launch does not match start_offset")
        parsed["mtime_ns_at_launch"] = positive(
            value.get("mtime_ns_at_launch", launch_mtime),
            f"{label}.mtime_ns_at_launch",
        )
    elif start != 0:
        # A source created after launch has no pre-existing bytes to skip. A
        # non-zero cursor here would let a caller hide stale initial content.
        fail(f"{label}.start_offset must be zero for a post-launch source")
    return parsed


def check_existing_source(
    path: pathlib.Path,
    boundary: dict[str, Any],
    label: str,
) -> os.stat_result:
    try:
        stat = path.stat()
    except OSError as exc:
        fail(f"{label} cannot be stat'ed: {exc}")
    if not path.is_file() or not os.access(path, os.R_OK):
        fail(f"{label} is missing or unreadable")
    if boundary["exists_at_launch"]:
        if stat.st_dev != boundary["device"] or stat.st_ino != boundary["inode"]:
            fail(f"{label} identity was replaced")
        if stat.st_size < boundary["start_offset"]:
            fail(f"{label} was truncated before launch boundary")
        if stat.st_mtime_ns < boundary["mtime_ns_at_launch"]:
            fail(f"{label} mtime predates launch")
    else:
        if stat.st_mtime_ns < boundary["launch_mtime_ns"]:
            fail(f"{label} was created before launch")
        birth = getattr(stat, "st_birthtime_ns", None)
        if birth is None:
            birth = getattr(stat, "st_ctime_ns", None)
        if birth is not None and birth < boundary["launch_mtime_ns"]:
            fail(f"{label} identity predates launch")
    return stat


def check_result_source(
    path: pathlib.Path,
    boundary: dict[str, Any],
    state: dict[str, Any],
) -> os.stat_result | None:
    try:
        stat = path.stat()
    except FileNotFoundError:
        stat = None
    except OSError as exc:
        fail(f"result source cannot be stat'ed: {exc}")
    if stat is None:
        if boundary["exists_at_launch"] or state.get("result_inode") is not None:
            fail("result source disappeared after launch")
        return None
    if not path.is_file() or not os.access(path, os.R_OK | os.W_OK):
        fail("result source is not a readable writable regular file")
    if boundary["exists_at_launch"]:
        if stat.st_dev != boundary["device"] or stat.st_ino != boundary["inode"]:
            fail("result source identity was replaced")
        if stat.st_size < boundary["start_offset"]:
            fail("result source was truncated before launch boundary")
        if stat.st_mtime_ns < boundary["mtime_ns_at_launch"]:
            fail("result source mtime predates launch")
    else:
        if stat.st_mtime_ns < boundary["launch_mtime_ns"]:
            fail("result source was created before launch")
        birth = getattr(stat, "st_birthtime_ns", None)
        if birth is None:
            birth = getattr(stat, "st_ctime_ns", None)
        if birth is not None and birth < boundary["launch_mtime_ns"]:
            fail("result source identity predates launch")
    old_device = state.get("result_device")
    old_inode = state.get("result_inode")
    if old_device is not None and old_device != stat.st_dev:
        fail("result source device changed")
    if old_inode is not None and old_inode != stat.st_ino:
        fail("result source inode changed")
    old_mtime = state.get("result_mtime_ns")
    if old_mtime is not None and (not isinstance(old_mtime, int) or stat.st_mtime_ns < old_mtime):
        fail("result source mtime moved backwards")
    return stat


def source_checkpoint(path: pathlib.Path, end: int) -> str:
    """Hash every consumed source byte, not only its edge windows.

    The checkpoint protects the persisted prefix that the next callback will
    rely on for replay/truncation detection. Sampling only the first and last
    windows would let a middle-byte mutation preserve the checkpoint.
    """
    digest = hashlib.sha256(str(end).encode("ascii") + b"\0")
    remaining = end
    try:
        with path.open("rb") as stream:
            while remaining:
                chunk = stream.read(min(1024 * 1024, remaining))
                if not chunk:
                    fail("source changed while reading its boundary")
                digest.update(chunk)
                remaining -= len(chunk)
    except OSError as exc:
        fail(f"cannot read source boundary: {exc}")
    digest.update(b"\0")
    return digest.hexdigest()


def content_text(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float, bool)):
        return str(value)
    if isinstance(value, list):
        return "\n".join(part for item in value if (part := content_text(item)))
    if isinstance(value, dict):
        for key in ("text", "content", "value", "output"):
            if key in value:
                return content_text(value[key])
    return ""


def model_content(entry: dict[str, Any]) -> str:
    role = content_text(entry.get("role")).casefold()
    source = content_text(entry.get("source")).casefold()
    kind = content_text(entry.get("type", entry.get("kind", ""))).casefold()
    authored = source in {"model", "assistant"} or role in {"model", "assistant"}
    if not authored:
        return ""
    # Tool-call/result records are not completion evidence. Real agy model
    # output uses response/output/planner record kinds; retain an untyped model
    # record for older product versions.
    if source == "model" and kind and not any(
        word in kind for word in ("response", "output", "planner")
    ) and role != "assistant":
        return ""
    for key in ("content", "text", "output", "message"):
        value = content_text(entry.get(key))
        if value.strip():
            return value
    return ""


def validate_record_correlation(entry: dict[str, Any], conversation: str) -> None:
    record_nonce = entry.get("job_nonce", entry.get("jobNonce"))
    if record_nonce is not None:
        record_nonce = bounded_text(record_nonce, "transcript record job_nonce")
        if record_nonce != nonce:
            fail("transcript record job_nonce does not match the active job")
    for key in (
        "conversationId",
        "conversation_id",
        "conversationID",
        "sessionId",
        "session_id",
        "executor_session",
    ):
        value = entry.get(key)
        if value is None:
            continue
        value = bounded_text(value, f"transcript record {key}")
        if value != conversation:
            fail(f"transcript record {key} does not match the hook conversation")


def capture_fresh_transcript(
    source: pathlib.Path,
    source_stat: os.stat_result,
    last_offset: int,
    staged_result_path: pathlib.Path,
    job_dir: pathlib.Path,
    conversation: str,
) -> tuple[int, int, str, pathlib.Path]:
    """Validate and stage one bounded fresh transcript segment.

    The source is streamed line-by-line and model output is staged in a
    durable transaction file.  This keeps transcript bytes, parsed records,
    and result output out of unbounded Python lists/strings while ensuring
    the source cursor is committed only after result/event evidence is ready.
    """
    fresh_size = source_stat.st_size - last_offset
    if fresh_size < 0:
        fail("transcript source was truncated or replaced")
    if fresh_size > MAX_TRANSCRIPT_DELTA_BYTES:
        fail("transcript delta is too large")

    complete_offset = last_offset
    records_seen = 0
    normalized_records = 0
    normalized_output_bytes = 0
    staged_path: pathlib.Path | None = None
    staged_stream = None
    remaining = fresh_size
    try:
        try:
            with source.open("rb") as stream:
                fd_stat = os.fstat(stream.fileno())
                if fd_stat.st_dev != source_stat.st_dev or fd_stat.st_ino != source_stat.st_ino:
                    fail("transcript source identity changed while opening")
                stream.seek(last_offset)
                while remaining:
                    # Leave room for CRLF while retaining a strict bound on
                    # the decoded JSONL record itself.  Never read beyond the
                    # source size captured by source_stat.
                    read_limit = min(remaining, MAX_TRANSCRIPT_RECORD_BYTES + 2)
                    piece = stream.readline(read_limit)
                    if not piece:
                        fail("transcript source changed while reading")
                    remaining -= len(piece)
                    if not piece.endswith((b"\n", b"\r")):
                        if len(piece) > MAX_TRANSCRIPT_RECORD_BYTES or remaining:
                            fail("transcript record is too large or source changed")
                        # A final partial line is deliberately left for the
                        # next callback, matching the adapter cursor contract.
                        break
                    line = piece.rstrip(b"\r\n")
                    if len(line) > MAX_TRANSCRIPT_RECORD_BYTES:
                        fail("transcript record is too large")
                    complete_offset += len(piece)
                    records_seen += 1
                    if records_seen > MAX_TRANSCRIPT_RECORDS:
                        fail("transcript record count is too large")
                    if not line.strip():
                        continue
                    try:
                        entry = json.loads(
                            line.decode("utf-8"),
                            object_pairs_hook=reject_duplicate_keys,
                        )
                    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
                        fail(f"malformed transcript JSONL at source offset {complete_offset - len(piece)}: {exc}")
                    if not isinstance(entry, dict):
                        fail("transcript record is not an object")
                    validate_record_correlation(entry, conversation)
                    content = model_content(entry)
                    if not content:
                        continue
                    normalized = (content.rstrip("\n") + "\n").encode("utf-8")
                    if normalized_output_bytes + len(normalized) > MAX_NORMALIZED_OUTPUT_BYTES:
                        fail("normalized output is too large")
                    if staged_stream is None:
                        try:
                            temp_fd, temp_name = tempfile.mkstemp(
                                prefix="agy-hook-output.", dir=str(job_dir)
                            )
                            staged_path = pathlib.Path(temp_name)
                            staged_stream = os.fdopen(temp_fd, "wb")
                        except OSError as exc:
                            fail(f"cannot stage normalized output: {exc}")
                    try:
                        staged_stream.write(normalized)
                    except OSError as exc:
                        fail(f"cannot stage normalized output: {exc}")
                    normalized_output_bytes += len(normalized)
                    normalized_records += 1
        except OSError as exc:
            fail(f"cannot read transcript source: {exc}")
        if remaining:
            fail("transcript source changed while reading")
        try:
            after_read_stat = source.stat()
        except OSError as exc:
            fail(f"cannot stat transcript source after reading: {exc}")
        if after_read_stat.st_dev != source_stat.st_dev or after_read_stat.st_ino != source_stat.st_ino:
            fail("transcript source identity changed while reading")
        if after_read_stat.st_size < source_stat.st_size or after_read_stat.st_mtime_ns < source_stat.st_mtime_ns:
            fail("transcript source changed while reading")

        if staged_stream is not None:
            try:
                staged_stream.flush()
                os.fsync(staged_stream.fileno())
                staged_stream.close()
            except OSError as exc:
                fail(f"cannot stage normalized output: {exc}")
            staged_stream = None

        # Verify the source boundary before making the staged result visible
        # to transaction recovery.  The result sink is not appended here.
        final_source_checkpoint = source_checkpoint(source, complete_offset)
        if staged_path is not None:
            try:
                os.replace(staged_path, staged_result_path)
                staged_path = None
                directory_fd = os.open(str(staged_result_path.parent), os.O_RDONLY)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
            except OSError as exc:
                fail(f"cannot persist staged result source: {exc}")
        elif staged_result_path.exists():
            try:
                staged_result_path.unlink()
            except OSError as exc:
                fail(f"cannot clear empty staged result source: {exc}")
        return complete_offset, normalized_records, final_source_checkpoint, staged_result_path
    finally:
        if staged_stream is not None:
            try:
                staged_stream.close()
            except OSError:
                pass
        if staged_path is not None:
            try:
                staged_path.unlink()
            except FileNotFoundError:
                pass
            except OSError:
                pass


def fsync_directory(path: pathlib.Path) -> None:
    try:
        directory_fd = os.open(str(path), os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except OSError as exc:
        fail(f"cannot persist directory metadata: {exc}")


def atomic_write(path: pathlib.Path, payload: bytes, label: str) -> None:
    """Durably replace one transaction/control file without partial JSON."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path: pathlib.Path | None = None
    try:
        temp_fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
        temp_path = pathlib.Path(temp_name)
        with os.fdopen(temp_fd, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_path, path)
        fsync_directory(path.parent)
    except OSError as exc:
        fail(f"cannot persist {label}: {exc}")
    finally:
        if temp_path is not None:
            try:
                temp_path.unlink()
            except FileNotFoundError:
                pass


def state_bytes(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, separators=(",", ":")) + "\n").encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


_TEST_CRASH_AT = next(
    (
        os.environ.get(name, "")
        for name in (
            "CMUX_AGENT_TEST_CRASH_AT",
            "CMUX_AGENT_BRIDGE_CRASH_AT",
            "CMUX_AGENT_TEST_FAILURE_POINT",
        )
        if os.environ.get(name, "")
    ),
    "",
).casefold().replace("_", "-")


def maybe_test_crash(point: str) -> None:
    normalized = point.casefold().replace("_", "-")
    if _TEST_CRASH_AT in {
        normalized,
        f"after-{normalized}",
        f"after-{normalized}-append",
        f"after-{normalized}-write",
    }:
        os._exit(97)


def append_bytes(path: pathlib.Path, payload: bytes, label: str) -> None:
    try:
        fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            view = memoryview(payload)
            while view:
                count = os.write(fd, view)
                if count <= 0:
                    raise OSError("short write")
                view = view[count:]
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError as exc:
        fail(f"cannot append {label}: {exc}")


def apply_result_payload(payload: bytes, base_offset: int) -> None:
    """Apply one staged plain-text result exactly once."""
    try:
        current_size = result_path.stat().st_size
    except FileNotFoundError:
        current_size = 0
    except OSError as exc:
        fail(f"cannot stat result source: {exc}")
    if current_size < base_offset:
        fail("result source was truncated before the pending transaction")
    expected_end = base_offset + len(payload)
    if current_size > base_offset:
        try:
            with result_path.open("rb") as stream:
                stream.seek(base_offset)
                existing = stream.read(max(1, min(len(payload) + 1, current_size - base_offset)))
        except OSError as exc:
            fail(f"cannot inspect result source: {exc}")
        if existing != payload[: len(existing)]:
            fail("result source contains unexpected bytes after the transaction boundary")
        if current_size > expected_end:
            fail("result source contains an unexpected later transaction")
        if current_size < expected_end:
            try:
                with result_path.open("r+b") as stream:
                    stream.truncate(base_offset)
                    stream.flush()
                    os.fsync(stream.fileno())
            except OSError as exc:
                fail(f"cannot repair partial result source: {exc}")
            current_size = base_offset
    if current_size == expected_end:
        return
    if current_size != base_offset:
        fail("result source cursor is inconsistent")
    append_bytes(result_path, payload, "result source")


def result_payload_present(base_offset: int, payload_size: int, payload_digest: str) -> bool:
    try:
        current_size = result_path.stat().st_size
    except FileNotFoundError:
        return payload_size == 0 and base_offset == 0
    except OSError as exc:
        fail(f"cannot stat result source: {exc}")
    expected_end = base_offset + payload_size
    if current_size != expected_end:
        if current_size < expected_end:
            return False
        fail("result source has bytes beyond the pending transaction")
    try:
        with result_path.open("rb") as stream:
            stream.seek(base_offset)
            payload = stream.read(payload_size)
    except OSError as exc:
        fail(f"cannot inspect result source: {exc}")
    if sha256_bytes(payload) != payload_digest:
        fail("result source does not match the pending transaction")
    return True


def event_present(
    event_id: str,
    pending_line: bytes | None = None,
    pending_base_offset: int | None = None,
) -> bool:
    if not sink_path.exists():
        return False
    try:
        with sink_path.open("rb") as stream:
            sink_offset = 0
            for line_number, line in enumerate(stream, 1):
                line_start = sink_offset
                sink_offset += len(line)
                if not line.endswith(b"\n"):
                    if pending_line is not None and pending_base_offset == line_start:
                        try:
                            sink_size = sink_path.stat().st_size
                            with sink_path.open("rb") as inspect:
                                inspect.seek(pending_base_offset)
                                partial = inspect.read(sink_size - pending_base_offset)
                            if (
                                pending_base_offset <= sink_size <= pending_base_offset + len(pending_line)
                                and pending_line.startswith(partial)
                            ):
                                with sink_path.open("r+b") as repair:
                                    repair.truncate(pending_base_offset)
                                    repair.flush()
                                    os.fsync(repair.fileno())
                                return False
                        except OSError as exc:
                            fail(f"cannot repair incomplete event sink record: {exc}")
                    fail(f"event sink has an incomplete record at line {line_number}")
                if not line.strip():
                    continue
                try:
                    value = json.loads(line.decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
                except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
                    fail(f"event sink is malformed at line {line_number}: {exc}")
                if not isinstance(value, dict):
                    fail(f"event sink record at line {line_number} is not an object")
                if value.get("event_id") == event_id:
                    if value.get("job_nonce") != nonce:
                        fail("event identity is claimed by another job")
                    if value.get("executor_session") != value.get("conversation_id"):
                        fail("event identity has conflicting session fields")
                    return True
    except OSError as exc:
        fail(f"cannot inspect event sink: {exc}")
    return False


def append_event_line(
    event_line: bytes,
    event_id: str,
    pending_base_offset: int | None = None,
) -> bool:
    if event_present(event_id, event_line, pending_base_offset):
        return False
    append_bytes(sink_path, event_line, "lifecycle event")
    return True


def load_pending() -> dict[str, Any] | None:
    if not pending_meta_path.exists():
        return None
    value = load_json(pending_meta_path, "pending agy transaction")
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        fail("pending agy transaction is malformed")
    if value.get("job_nonce") != nonce or value.get("mapping_path") != str(mapping_path):
        fail("pending agy transaction belongs to another job")
    if value.get("result_path") != str(result_path) or value.get("event_path") != str(sink_path):
        fail("pending agy transaction paths do not match")
    return value


def load_pending_state(expected_digest: str) -> dict[str, Any]:
    try:
        raw = pending_state_path.read_bytes()
        value = json.loads(raw.decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
        fail(f"pending agy state is malformed: {exc}")
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        fail("pending agy state is malformed")
    if sha256_bytes(raw) != expected_digest:
        fail("pending agy state digest does not match")
    if value.get("job_nonce") != nonce or value.get("mapping_path") != str(mapping_path):
        fail("pending agy state belongs to another job")
    return value


def validate_pending_source(meta: dict[str, Any]) -> None:
    raw_path = meta.get("source_path")
    complete_end = meta.get("complete_end")
    source_device = meta.get("source_device")
    source_inode = meta.get("source_inode")
    expected_checkpoint = meta.get("source_checkpoint")
    if (
        raw_path != source_path
        or not isinstance(complete_end, int)
        or isinstance(complete_end, bool)
        or complete_end < 0
        or not isinstance(source_device, int)
        or isinstance(source_device, bool)
        or not isinstance(source_inode, int)
        or isinstance(source_inode, bool)
        or not isinstance(expected_checkpoint, str)
    ):
        fail("pending agy source boundary is malformed")
    source = pathlib.Path(raw_path)
    try:
        stat = source.stat()
    except OSError as exc:
        fail(f"cannot stat pending agy transcript source: {exc}")
    if stat.st_dev != source_device or stat.st_ino != source_inode or stat.st_size < complete_end:
        fail("pending agy transcript source identity or size changed")
    if source_checkpoint(source, complete_end) != expected_checkpoint:
        fail("pending agy transcript source prefix changed")


def remove_pending() -> None:
    for path in (pending_meta_path, pending_result_path, pending_event_path, pending_state_path):
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            fail(f"cannot remove pending agy transaction: {exc}")
    fsync_directory(job_dir)


def recover_pending(current_state: dict[str, Any]) -> tuple[dict[str, Any], bool]:
    """Finish a staged result/event before consuming new transcript bytes."""
    meta = load_pending()
    if meta is None:
        for path in (pending_result_path, pending_event_path, pending_state_path):
            try:
                path.unlink()
            except FileNotFoundError:
                pass
            except OSError as exc:
                fail(f"cannot remove abandoned pending agy file: {exc}")
        return current_state, False

    validate_pending_source(meta)
    event_id = meta.get("event_id")
    base_offset = meta.get("result_base_offset")
    payload_size = meta.get("result_payload_size")
    payload_digest = meta.get("result_payload_sha256")
    event_base_offset = meta.get("event_base_offset")
    base_state_digest = meta.get("base_state_sha256")
    if (
        not isinstance(event_id, str)
        or not isinstance(event_base_offset, int)
        or isinstance(event_base_offset, bool)
        or event_base_offset < 0
        or not isinstance(base_offset, int)
        or isinstance(base_offset, bool)
        or base_offset < 0
        or not isinstance(payload_size, int)
        or isinstance(payload_size, bool)
        or payload_size < 0
        or not isinstance(payload_digest, str)
        or not isinstance(base_state_digest, str)
    ):
        fail("pending agy transaction metadata is malformed")

    candidate: dict[str, Any] | None = None
    if pending_state_path.exists():
        pending_state_digest = meta.get("pending_state_sha256")
        if not isinstance(pending_state_digest, str):
            fail("pending agy state digest is missing")
        candidate = load_pending_state(pending_state_digest)
    committed = candidate is not None and current_state == candidate
    if candidate is None:
        pending_state_digest = meta.get("pending_state_sha256")
        committed = (
            isinstance(pending_state_digest, str)
            and sha256_bytes(state_bytes(current_state)) == pending_state_digest
        )
    if committed:
        if not result_payload_present(base_offset, payload_size, payload_digest):
            fail("committed agy state has no matching result evidence")
        pending_event = None
        if pending_event_path.exists():
            pending_event = pending_event_path.read_bytes()
        if not event_present(event_id, pending_event, event_base_offset):
            if pending_event is None:
                fail("committed agy state has no matching lifecycle evidence")
            event_line = pending_event
            if sha256_bytes(event_line) != meta.get("event_line_sha256"):
                fail("pending agy lifecycle evidence digest does not match")
            append_event_line(event_line, event_id, event_base_offset)
        remove_pending()
        return current_state, True

    if sha256_bytes(state_bytes(current_state)) != base_state_digest:
        fail("pending agy transaction does not match durable hook state")
    if candidate is None:
        fail("pending agy state is missing")
    if not pending_result_path.exists() or not pending_event_path.exists():
        fail("pending agy evidence is incomplete")
    result_payload = pending_result_path.read_bytes()
    event_line = pending_event_path.read_bytes()
    if len(result_payload) != payload_size or sha256_bytes(result_payload) != payload_digest:
        fail("pending agy result digest does not match")
    if sha256_bytes(event_line) != meta.get("event_line_sha256") or not event_line.endswith(b"\n"):
        fail("pending agy lifecycle evidence is malformed")

    apply_result_payload(result_payload, base_offset)
    maybe_test_crash("result")
    append_event_line(event_line, event_id, event_base_offset)
    maybe_test_crash("event")
    maybe_test_crash("before-state")
    try:
        os.replace(pending_state_path, state_path)
        fsync_directory(job_dir)
    except OSError as exc:
        fail(f"cannot commit agy hook state: {exc}")
    maybe_test_crash("state")
    maybe_test_crash("after-state")
    remove_pending()
    return candidate, True


def commit_transaction(
    event: dict[str, Any],
    next_state: dict[str, Any],
    result_base_offset: int,
    source: pathlib.Path,
    source_stat: os.stat_result,
    complete_end: int,
    source_digest: str,
) -> tuple[dict[str, Any], bool]:
    if pending_meta_path.exists():
        fail("another pending agy transaction is active")
    for path in (pending_event_path, pending_state_path):
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            fail(f"cannot clear stale pending agy file: {exc}")
    try:
        result_payload = pending_result_path.read_bytes()
    except OSError as exc:
        fail(f"cannot read staged agy result: {exc}")
    if len(result_payload) > MAX_NORMALIZED_OUTPUT_BYTES:
        fail("staged agy result is too large")
    event_line = (json.dumps(event, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
    candidate_bytes = state_bytes(next_state)
    atomic_write(pending_event_path, event_line, "pending agy event")
    atomic_write(pending_state_path, candidate_bytes, "pending agy state")
    try:
        event_base_offset = sink_path.stat().st_size
    except FileNotFoundError:
        event_base_offset = 0
    except OSError as exc:
        fail(f"cannot stat lifecycle event sink: {exc}")
    metadata = {
        "schema_version": 1,
        "job_nonce": nonce,
        "mapping_path": str(mapping_path),
        "result_path": str(result_path),
        "event_path": str(sink_path),
        "source_path": str(source),
        "source_device": source_stat.st_dev,
        "source_inode": source_stat.st_ino,
        "complete_end": complete_end,
        "source_checkpoint": source_digest,
        "result_base_offset": result_base_offset,
        "result_payload_size": len(result_payload),
        "result_payload_sha256": sha256_bytes(result_payload),
        "event_id": event["event_id"],
        "event_base_offset": event_base_offset,
        "event_line_sha256": sha256_bytes(event_line),
        "pending_state_sha256": sha256_bytes(candidate_bytes),
        "base_state_sha256": sha256_bytes(state_bytes(state)),
    }
    atomic_write(
        pending_meta_path,
        (json.dumps(metadata, separators=(",", ":")) + "\n").encode("utf-8"),
        "pending agy transaction",
    )
    committed_state, _ = recover_pending(state)
    return committed_state, True


try:
    payload_raw = pathlib.Path(payload_path).read_bytes()
    if len(payload_raw) > MAX_HOOK_PAYLOAD_BYTES:
        fail("hook payload is too large")
    payload = json.loads(payload_raw.decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
except (OSError, UnicodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
    fail(f"hook payload is malformed: {exc}")
if not isinstance(payload, dict):
    fail("hook payload is not an object")

transcript_payload_path = canonical_path(payload.get("transcriptPath"), "transcriptPath")
conversation = bounded_text(payload.get("conversationId"), "conversationId")
invocation = payload.get("invocationNum")
if isinstance(invocation, bool) or not isinstance(invocation, int) or invocation < 0 or invocation > MAX_INT:
    fail("invocationNum must be a bounded non-negative integer")
if not HANDLE_RE.fullmatch(nonce):
    fail("job nonce is malformed")

runtime = pathlib.Path(canonical_path(runtime_raw, "runtime"))
# The per-job variable is required even when a legacy/common runtime variable
# happens to point at the same directory.  The hook must never select an
# ambient runtime in place of the supervisor's active-job binding.
common_runtime_raw = os.environ.get("CMUX_AGENT_RUNTIME", "")
if common_runtime_raw and canonical_path(common_runtime_raw, "CMUX_AGENT_RUNTIME") != str(runtime):
    fail("CMUX_AGENT_RUNTIME does not match the supervisor per-job runtime")
result_path = pathlib.Path(canonical_path(result_raw, "result source"))
sink_path = pathlib.Path(canonical_path(sink_raw, "event sink"))
job_dir = runtime / "jobs" / nonce
mapping_path = job_dir / "agy.mapping.json"
legacy_mapping = job_dir / "mapping.json"
if not mapping_path.is_file() or legacy_mapping.exists():
    fail("active supervisor mapping is missing or ambiguous")
mapping = load_json(mapping_path, "active supervisor mapping")
if not isinstance(mapping, dict):
    fail("active supervisor mapping is not an object")
if type(mapping.get("schema_version")) is not int or mapping.get("schema_version") != 1:
    fail("active supervisor mapping schema is unsupported")
if mapping.get("job_nonce") != nonce:
    fail("active supervisor mapping nonce does not match")
if canonical_path(mapping.get("runtime"), "mapping.runtime") != str(runtime):
    fail("active supervisor mapping runtime does not match")
for key in ("workspace", "surface"):
    if key in mapping:
        bounded_text(mapping[key], f"mapping.{key}")
if "cwd" in mapping:
    cwd = canonical_path(mapping["cwd"], "mapping.cwd")
    if not os.path.isabs(cwd):
        fail("mapping.cwd must be absolute")

source_map = mapping.get("source")
source_path = map_path(source_map, "mapping.source") if isinstance(source_map, dict) else fail("mapping.source is missing")
source_boundary = parse_boundary(source_map, "mapping.source")
if transcript_payload_path != source_path:
    fail("hook transcriptPath does not match the configured source")

result_map = mapping.get("result")
result_configured_path = map_path(result_map, "mapping.result") if isinstance(result_map, dict) else fail("mapping.result is missing")
result_boundary = parse_boundary(result_map, "mapping.result")
if result_configured_path != str(result_path):
    fail("configured result path does not match the profile result source")

state_path = job_dir / "agy-hook.state.json"
lock_path = job_dir / ".agy-hook.lock"
event_lock_path = sink_path.parent / ".cmux-agent-event-sink.lock"
pending_meta_path = job_dir / ".agy-hook.pending.json"
pending_result_path = job_dir / ".agy-hook.pending.result"
pending_event_path = job_dir / ".agy-hook.pending.event"
pending_state_path = job_dir / ".agy-hook.pending.state"
sink_path.parent.mkdir(parents=True, exist_ok=True)
try:
    lock = lock_path.open("a+")
except OSError as exc:
    fail(f"cannot lock active job: {exc}")
with lock:
    try:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        # The lifecycle sink is shared by jobs. Pairing one lock with event
        # deduplication prevents a replay from racing a normal callback.
        event_lock = event_lock_path.open("a+")
        fcntl.flock(event_lock.fileno(), fcntl.LOCK_EX)
    except OSError as exc:
        fail(f"cannot lock active job: {exc}")

    state: dict[str, Any] = {}
    if state_path.exists():
        value = load_json(state_path, "agy hook state")
        if not isinstance(value, dict):
            fail("agy hook state is not an object")
        state = value
        if state.get("schema_version") != 1 or state.get("job_nonce") != nonce:
            fail("agy hook state belongs to another job")
        if state.get("mapping_path") != str(mapping_path):
            fail("agy hook state mapping does not match")
        state_result_path = state.get("result_path")
        if state_result_path is not None and canonical_path(state_result_path, "state.result_path") != str(result_path):
            fail("agy hook state result path does not match")

    # Complete any staged evidence from a previous callback before reading new
    # transcript bytes. Replays therefore recover the cursor once and emit no
    # second result or lifecycle event.
    state, recovered_transaction = recover_pending(state)

    source = pathlib.Path(source_path)
    source_stat = check_existing_source(source, source_boundary, "transcript source")
    old_source_path = state.get("source_path")
    if old_source_path is not None and canonical_path(old_source_path, "state.source_path") != source_path:
        fail("transcript source changed during the active job")
    for field, stat_field in (("source_device", "st_dev"), ("source_inode", "st_ino")):
        old_value = state.get(field)
        if old_value is not None and old_value != getattr(source_stat, stat_field):
            fail(f"transcript source {field.replace('source_', '', 1)} changed")
    old_source_mtime = state.get("source_mtime_ns")
    if old_source_mtime is not None and (
        not isinstance(old_source_mtime, int) or source_stat.st_mtime_ns < old_source_mtime
    ):
        fail("transcript source mtime moved backwards")
    last_offset = nonnegative(state.get("last_source_offset", source_boundary["start_offset"]), "state.last_source_offset")
    if last_offset < source_boundary["start_offset"] or source_stat.st_size < last_offset:
        fail("transcript source was truncated or replaced")
    previous_checkpoint = state.get("source_checkpoint")
    if previous_checkpoint is not None:
        if not isinstance(previous_checkpoint, str) or previous_checkpoint != source_checkpoint(source, last_offset):
            fail("transcript source prefix was replaced")

    result_stat = check_result_source(result_path, result_boundary, state)
    result_offset = result_stat.st_size if result_stat is not None else 0
    if result_stat is not None and result_offset < result_boundary["start_offset"]:
        fail("result source is before its launch boundary")

    complete_offset, normalized_records, final_source_checkpoint, staged_result = capture_fresh_transcript(
        source,
        source_stat,
        last_offset,
        pending_result_path,
        job_dir,
        conversation,
    )
    if not staged_result.exists():
        atomic_write(staged_result, b"", "empty staged agy result")

    # Event identity is derived from agy-owned source size, so a replay of the
    # same callback is idempotent even if the previous process died after
    # writing evidence but before committing its source cursor.
    event = {
        "schema_version": 1,
        "hook_event_name": "PostInvocation",
        "hook": "agy-result-hook",
        "job_nonce": nonce,
        "event_id": f"{nonce}:{conversation}:{invocation}:{source_stat.st_size}",
        "executor_session": conversation,
        "conversation_id": conversation,
        "invocation_num": invocation,
        "transcript_path": source_path,
        "transcript_size": source_stat.st_size,
        "transcript_offset": result_offset,
        "source_offset": complete_offset,
        "source_start_offset": source_boundary["start_offset"],
        "normalized_records": normalized_records,
        "status": "success",
    }
    try:
        final_result_stat = result_path.stat()
    except FileNotFoundError:
        final_result_stat = None
    except OSError as exc:
        fail(f"cannot stat result source before commit: {exc}")
    new_state = {
        "schema_version": 1,
        "job_nonce": nonce,
        "mapping_path": str(mapping_path),
        "source_path": source_path,
        "source_device": source_stat.st_dev,
        "source_inode": source_stat.st_ino,
        "source_mtime_ns": source_stat.st_mtime_ns,
        "source_start_offset": source_boundary["start_offset"],
        "source_launch_mtime_ns": source_boundary["launch_mtime_ns"],
        "source_exists_at_launch": source_boundary["exists_at_launch"],
        "source_created_after_launch": source_boundary["created_after_launch"],
        "last_source_offset": complete_offset,
        "source_checkpoint": final_source_checkpoint,
        "result_path": str(result_path),
        "result_device": final_result_stat.st_dev if final_result_stat is not None else None,
        "result_inode": final_result_stat.st_ino if final_result_stat is not None else None,
        "result_mtime_ns": final_result_stat.st_mtime_ns if final_result_stat is not None else None,
        "result_start_offset": result_boundary["start_offset"],
        "normalized_records": nonnegative(state.get("normalized_records", 0), "state.normalized_records") + normalized_records,
        "events_seen": nonnegative(state.get("events_seen", 0), "state.events_seen") + 1,
    }
    state, _ = commit_transaction(
        event,
        new_state,
        result_offset,
        source,
        source_stat,
        complete_offset,
        final_source_checkpoint,
    )
PY

# The agy PostInvocation hook stdout contract requires a JSON object.
echo '{}'
