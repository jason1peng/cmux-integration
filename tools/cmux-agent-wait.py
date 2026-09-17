#!/usr/bin/env python3
"""Wait for one runner-owned cmux-agent result manifest.

The manifest is the only completion protocol.  This helper never reads a pane,
provider transcript, task file, or output capture, and it never terminates a
process.  It polls the atomically replaced ``result.json`` until the runner
publishes one of the four terminal statuses or until the runner deadline, stop
grace, and safety margin have all elapsed.
"""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import time
from typing import Any, Callable

SCHEMA_VERSION = 1
MAX_MANIFEST_BYTES = 128 * 1024
MAX_ID_BYTES = 256
MAX_PATH_BYTES = 4096
MAX_TIMEOUT_SECONDS = 24 * 60 * 60
MAX_STOP_DEADLINE_SECONDS = 300
MAX_POLL_INTERVAL_SECONDS = 60
MAX_SAFETY_MARGIN_SECONDS = 300
MAX_MISSING_RESULT_GRACE_SECONDS = 60
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
TERMINAL_STATUSES = frozenset({"completed", "failed", "timed_out", "cancelled"})
NON_TERMINAL_STATUSES = frozenset({"starting", "running"})
KNOWN_STATUSES = TERMINAL_STATUSES | NON_TERMINAL_STATUSES

# This is intentionally the runner's complete schema, rather than an
# open-ended dictionary.  An unknown field is evidence from an unreviewed
# producer and must not influence a completion decision.
KNOWN_FIELDS = frozenset(
    {
        "schema_version",
        "job_nonce",
        "profile_id",
        "workspace",
        "surface",
        "cwd",
        "status",
        "started_at_ns",
        "task_sha256",
        "stdout_path",
        "stderr_path",
        "result_path",
        "permission_mode",
        "input",
        "sandbox",
        "network",
        "write_scope",
        "dangerous",
        "force",
        "yolo",
        "executable",
        "result_format",
        "timeout_seconds",
        "deadline_at_ns",
        "stop_deadline_seconds",
        "command_sha256",
        "pid",
        "output_mirrored",
        "finished_at_ns",
        "duration_ms",
        "exit_code",
        "timed_out",
        "cancelled",
        "force_killed",
        "stdout_size",
        "stdout_sha256",
        "stderr_size",
        "stderr_sha256",
        "marker_observed",
        "error",
    }
)
REQUIRED_FIELDS = frozenset(
    {
        "schema_version",
        "job_nonce",
        "status",
        "started_at_ns",
        "result_path",
        "timeout_seconds",
        "deadline_at_ns",
        "stop_deadline_seconds",
    }
)


class WaitError(ValueError):
    """A malformed, stale, or unsafe result manifest."""


def error_text(exc: BaseException) -> str:
    text = f"{type(exc).__name__}: {exc}".strip()
    return text.encode("utf-8", "replace")[:512].decode("utf-8", "replace")


def safe_id(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > MAX_ID_BYTES:
        raise WaitError(f"{label} is missing or too long")
    if not ID_RE.fullmatch(value):
        raise WaitError(f"{label} is not a safe identifier")
    return value


def finite_number(value: Any, label: str, maximum: float, *, allow_zero: bool = False) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise WaitError(f"{label} must be a finite number")
    if allow_zero:
        invalid = value < 0
    else:
        invalid = value <= 0
    if invalid:
        raise WaitError(f"{label} must be {'non-negative' if allow_zero else 'positive'}")
    if value > maximum:
        raise WaitError(f"{label} is outside the supported bound")
    return float(value)


def positive_integer(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise WaitError(f"{label} must be a positive integer")
    return value


def canonical_result_path(raw: str) -> Path:
    if not isinstance(raw, str) or not raw or "\x00" in raw:
        raise WaitError("result path must be a non-empty path")
    if len(raw.encode("utf-8")) > MAX_PATH_BYTES:
        raise WaitError("result path is too long")
    path = Path(raw).expanduser()
    if not path.is_absolute():
        raise WaitError("result path must be absolute")
    # The runner uses an absolute, realpath-canonical path in its manifest.
    # Reject a symlink at the requested leaf before opening it, and compare
    # canonical paths below so /tmp versus /private/tmp remains portable.
    if path.is_symlink():
        raise WaitError(f"refusing symlink result path: {path}")
    try:
        return Path(os.path.realpath(path))
    except OSError as exc:
        raise WaitError("cannot canonicalize result path") from exc


def read_atomic(path: Path) -> bytes:
    """Read one complete inode, refusing symlink replacement and oversized data."""
    flags = os.O_RDONLY
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    flags |= nofollow
    try:
        fd = os.open(str(path), flags)
    except FileNotFoundError:
        raise
    except OSError as exc:
        raise WaitError(f"cannot open result manifest: {path}") from exc
    try:
        stat_result = os.fstat(fd)
        if not stat_result or not stat.S_ISREG(stat_result.st_mode):
            raise WaitError(f"result manifest is not a regular file: {path}")
        if stat_result.st_size > MAX_MANIFEST_BYTES:
            raise WaitError(f"result manifest is too large: {path}")
        with os.fdopen(fd, "rb") as stream:
            fd = -1
            data = stream.read(MAX_MANIFEST_BYTES + 1)
        if len(data) > MAX_MANIFEST_BYTES:
            raise WaitError(f"result manifest is too large: {path}")
        return data
    except OSError as exc:
        raise WaitError(f"cannot read result manifest: {path}") from exc
    finally:
        if fd >= 0:
            os.close(fd)


def parse_json(data: bytes) -> Any:
    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, item in pairs:
            if key in result:
                raise WaitError(f"duplicate manifest field: {key}")
            result[key] = item
        return result

    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, WaitError) as exc:
        raise WaitError("result manifest is malformed JSON") from exc


def validate_manifest(value: Any, expected_path: Path, expected_nonce: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise WaitError("result manifest must be an object")
    missing = REQUIRED_FIELDS - set(value)
    if missing:
        raise WaitError(f"result manifest is missing fields: {', '.join(sorted(missing))}")
    unknown = set(value) - KNOWN_FIELDS
    if unknown:
        raise WaitError(f"result manifest has unknown fields: {', '.join(sorted(unknown))}")
    if value["schema_version"] != SCHEMA_VERSION:
        raise WaitError("unsupported result manifest schema")

    nonce = safe_id(value["job_nonce"], "manifest job_nonce")
    if nonce != expected_nonce:
        raise WaitError("result manifest job_nonce does not match the requested job")
    status = value["status"]
    if not isinstance(status, str) or status not in KNOWN_STATUSES:
        raise WaitError("result manifest has an unknown status")

    manifest_path = canonical_result_path(value["result_path"])
    if manifest_path != expected_path:
        raise WaitError("result manifest result_path does not match the requested result")

    started_at_ns = positive_integer(value["started_at_ns"], "started_at_ns")
    deadline_at_ns = positive_integer(value["deadline_at_ns"], "deadline_at_ns")
    timeout_seconds = finite_number(value["timeout_seconds"], "timeout_seconds", MAX_TIMEOUT_SECONDS)
    expected_deadline = started_at_ns + max(1, math.ceil(timeout_seconds * 1_000_000_000))
    if deadline_at_ns != expected_deadline:
        raise WaitError("deadline_at_ns does not match timeout_seconds")
    if deadline_at_ns <= started_at_ns:
        raise WaitError("deadline_at_ns must be after started_at_ns")
    finite_number(
        value["stop_deadline_seconds"],
        "stop_deadline_seconds",
        MAX_STOP_DEADLINE_SECONDS,
    )

    # Validate bounded identity/path values if present without trusting them as
    # completion evidence.  The helper intentionally never opens these paths.
    for field in (
        "profile_id",
        "workspace",
        "surface",
        "cwd",
        "stdout_path",
        "stderr_path",
        "permission_mode",
        "input",
        "sandbox",
        "network",
        "executable",
        "result_format",
    ):
        if field in value and (
            not isinstance(value[field], str)
            or not value[field]
            or "\x00" in value[field]
            or len(value[field].encode("utf-8")) > MAX_PATH_BYTES
        ):
            raise WaitError(f"manifest {field} is malformed")
    if "write_scope" in value and (
        not isinstance(value["write_scope"], list)
        or len(value["write_scope"]) > 16
        or any(
            not isinstance(item, str)
            or not item
            or "\x00" in item
            or len(item.encode("utf-8")) > MAX_ID_BYTES
            for item in value["write_scope"]
        )
    ):
        raise WaitError("manifest write_scope is malformed")
    for field in ("pid", "finished_at_ns"):
        if field in value and (
            isinstance(value[field], bool)
            or not isinstance(value[field], int)
            or value[field] <= 0
        ):
            raise WaitError(f"manifest {field} is malformed")
    for field in ("stdout_size", "stderr_size"):
        if field in value and (
            isinstance(value[field], bool)
            or not isinstance(value[field], int)
            or value[field] < 0
        ):
            raise WaitError(f"manifest {field} is malformed")
    if "duration_ms" in value and (
        isinstance(value["duration_ms"], bool)
        or not isinstance(value["duration_ms"], (int, float))
        or not math.isfinite(value["duration_ms"])
        or value["duration_ms"] < 0
    ):
        raise WaitError("manifest duration_ms is malformed")
    if "exit_code" in value and (
        value["exit_code"] is not None
        and (
            isinstance(value["exit_code"], bool)
            or not isinstance(value["exit_code"], int)
        )
    ):
        raise WaitError("manifest exit_code is malformed")
    for field in ("task_sha256", "command_sha256", "stdout_sha256", "stderr_sha256"):
        if field in value and (
            not isinstance(value[field], str)
            or len(value[field]) != 64
            or any(character not in "0123456789abcdef" for character in value[field])
        ):
            raise WaitError(f"manifest {field} is malformed")
    if "error" in value and (
        not isinstance(value["error"], str)
        or "\x00" in value["error"]
        or len(value["error"].encode("utf-8")) > 512
    ):
        raise WaitError("manifest error is malformed")
    for field in (
        "dangerous",
        "force",
        "yolo",
        "output_mirrored",
        "timed_out",
        "cancelled",
        "force_killed",
        "marker_observed",
    ):
        if field in value and not isinstance(value[field], bool):
            raise WaitError(f"manifest {field} is malformed")
    if "timed_out" in value and value["timed_out"] != (status == "timed_out"):
        raise WaitError("manifest status conflicts with timed_out")
    if "cancelled" in value and value["cancelled"] != (status == "cancelled"):
        raise WaitError("manifest status conflicts with cancelled")

    return value


def read_manifest(path: Path, expected_nonce: str) -> dict[str, Any]:
    data = read_atomic(path)
    return validate_manifest(parse_json(data), path, expected_nonce)


def fence_at_ns(manifest: dict[str, Any], safety_margin_seconds: float) -> int:
    return manifest["deadline_at_ns"] + math.ceil(
        (float(manifest["stop_deadline_seconds"]) + safety_margin_seconds) * 1_000_000_000
    )


def identity_timing(manifest: dict[str, Any]) -> tuple[Any, ...]:
    """Fields that must remain stable across atomic manifest transitions."""
    return (
        manifest["schema_version"],
        manifest["job_nonce"],
        manifest["result_path"],
        manifest["started_at_ns"],
        manifest["timeout_seconds"],
        manifest["deadline_at_ns"],
        manifest["stop_deadline_seconds"],
    )


def result_evidence(
    *,
    job_nonce: str,
    result_path: Path,
    status: str,
    terminal: bool,
    fence_ns: int | None = None,
    observed_status: str | None = None,
    reason: str | None = None,
) -> dict[str, Any]:
    evidence: dict[str, Any] = {
        "job_nonce": job_nonce,
        "result_path": str(result_path),
        "status": status,
        "terminal": terminal,
    }
    if observed_status is not None:
        evidence["observed_status"] = observed_status
    if fence_ns is not None:
        evidence["fence_at_ns"] = fence_ns
    if reason is not None:
        evidence["reason"] = reason
    return evidence


def wait_for_result(
    result_path: Path,
    job_nonce: str,
    *,
    poll_interval_seconds: float = 1.0,
    safety_margin_seconds: float = 5.0,
    missing_result_grace_seconds: float = 5.0,
    clock_ns: Callable[[], int] = time.time_ns,
    sleep: Callable[[float], None] = time.sleep,
) -> tuple[int, dict[str, Any]]:
    """Return ``(exit_code, bounded evidence)`` for one result identity.

    Exit code 0 means a terminal manifest was observed, including a terminal
    ``failed``/``timed_out``/``cancelled`` job.  Exit code 1 means no terminal
    evidence was available by the fence.  Exit code 2 is a malformed, stale,
    or mismatched manifest/input.  The caller decides what the terminal status
    means for the task; this helper only owns waiting and fence decisions.
    """
    nonce = safe_id(job_nonce, "job_nonce")
    interval = finite_number(
        poll_interval_seconds,
        "poll_interval_seconds",
        MAX_POLL_INTERVAL_SECONDS,
    )
    safety = finite_number(
        safety_margin_seconds,
        "safety_margin_seconds",
        MAX_SAFETY_MARGIN_SECONDS,
        allow_zero=True,
    )
    missing_grace = finite_number(
        missing_result_grace_seconds,
        "missing_result_grace_seconds",
        MAX_MISSING_RESULT_GRACE_SECONDS,
        allow_zero=True,
    )
    expected_path = canonical_result_path(str(result_path))
    missing_until_ns = clock_ns() + math.ceil(missing_grace * 1_000_000_000)
    manifest: dict[str, Any] | None = None
    while manifest is None:
        try:
            manifest = read_manifest(expected_path, nonce)
        except FileNotFoundError:
            now_ns = clock_ns()
            if now_ns >= missing_until_ns:
                return 1, result_evidence(
                    job_nonce=nonce,
                    result_path=expected_path,
                    status="incomplete",
                    terminal=False,
                    reason="result manifest was not published",
                )
            sleep(min(interval, max(0.0, (missing_until_ns - now_ns) / 1_000_000_000)))
        except WaitError:
            raise

    fence_ns = fence_at_ns(manifest, safety)
    identity = identity_timing(manifest)
    observed_status = manifest["status"]
    while True:
        if observed_status in TERMINAL_STATUSES:
            return 0, result_evidence(
                job_nonce=nonce,
                result_path=expected_path,
                status=observed_status,
                terminal=True,
                fence_ns=fence_ns,
            )
        now_ns = clock_ns()
        if now_ns >= fence_ns:
            return 1, result_evidence(
                job_nonce=nonce,
                result_path=expected_path,
                status="incomplete",
                terminal=False,
                fence_ns=fence_ns,
                observed_status=observed_status,
                reason=(
                    "runner deadline, stop grace, and safety margin elapsed"
                    if observed_status != "missing"
                    else "result manifest disappeared before terminal evidence"
                ),
            )
        sleep(min(interval, max(0.0, (fence_ns - now_ns) / 1_000_000_000)))
        # The runner replaces the file atomically.  A malformed or mismatched
        # next manifest is an immediate fail-closed error, never a retry.
        try:
            next_manifest = read_manifest(expected_path, nonce)
        except FileNotFoundError:
            observed_status = "missing"
            continue
        if identity_timing(next_manifest) != identity:
            raise WaitError("result manifest identity or timing changed")
        manifest = next_manifest
        observed_status = manifest["status"]


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    identity = value.add_mutually_exclusive_group(required=False)
    identity.add_argument(
        "--result-path",
        "--result-file",
        "--result",
        dest="result_path",
        help="absolute runner-owned result.json path",
    )
    identity.add_argument(
        "--job-dir",
        help="job directory; result.json is appended (convenience form)",
    )
    value.add_argument("--job-nonce", required=True, help="expected fresh job nonce")
    value.add_argument(
        "--poll-interval-seconds",
        "--poll-interval",
        dest="poll_interval_seconds",
        type=float,
        default=1.0,
        help="bounded polling interval (default: 1)",
    )
    value.add_argument(
        "--safety-margin-seconds",
        "--safety-margin",
        "--margin-seconds",
        dest="safety_margin_seconds",
        type=float,
        default=5.0,
        help="fence margin after runner stop grace (default: 5)",
    )
    value.add_argument(
        "--missing-result-grace-seconds",
        type=float,
        default=5.0,
        help="bounded startup grace when result.json is not yet present (default: 5)",
    )
    return value


def main() -> int:
    args = parser().parse_args()
    try:
        if bool(args.result_path) == bool(args.job_dir):
            raise WaitError("exactly one of --result-path or --job-dir is required")
        raw_path = args.result_path or str(Path(args.job_dir).expanduser() / "result.json")
        exit_code, evidence = wait_for_result(
            Path(raw_path),
            args.job_nonce,
            poll_interval_seconds=args.poll_interval_seconds,
            safety_margin_seconds=args.safety_margin_seconds,
            missing_result_grace_seconds=args.missing_result_grace_seconds,
        )
        print(json.dumps(evidence, sort_keys=True, separators=(",", ":")))
        return exit_code
    except WaitError as exc:
        print(f"cmux-agent-wait: {error_text(exc)}", file=sys.stderr)
        return 2
    except (OSError, ValueError) as exc:
        print(f"cmux-agent-wait: operation failed safely: {error_text(exc)}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("cmux-agent-wait: interrupted; no cancellation was requested", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
