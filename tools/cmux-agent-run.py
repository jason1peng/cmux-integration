#!/usr/bin/env python3
"""Run one explicitly configured headless CLI and record its final metadata.

The runner is deliberately transport-neutral.  It never uses a shell, parses a
provider transcript, or treats terminal text as completion evidence.  It feeds
one task file to the profile's command, captures stdout/stderr, enforces a
bounded process-group timeout, and writes a small per-job result manifest.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any

SCHEMA_VERSION = 1
MAX_PROFILE_BYTES = 256 * 1024
MAX_TASK_BYTES = 1024 * 1024
MAX_PROMPT_ARG_BYTES = 128 * 1024
MAX_ID_BYTES = 256
MAX_ERROR_BYTES = 512
MAX_TIMEOUT_SECONDS = 24 * 60 * 60
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")


class RunnerError(ValueError):
    """A preflight or execution error that must fail closed."""


def error_text(exc: BaseException) -> str:
    text = f"{type(exc).__name__}: {exc}".strip()
    return text.encode("utf-8", "replace")[:MAX_ERROR_BYTES].decode("utf-8", "replace")


def safe_id(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > MAX_ID_BYTES:
        raise RunnerError(f"{label} is missing or too long")
    if not ID_RE.fullmatch(value):
        raise RunnerError(f"{label} is not a safe identifier")
    return value


def bounded_string(value: Any, label: str, *, allow_empty: bool = False) -> str:
    if not isinstance(value, str) or (not allow_empty and not value):
        raise RunnerError(f"{label} must be a string")
    if "\x00" in value:
        raise RunnerError(f"{label} contains NUL")
    if len(value.encode("utf-8")) > MAX_ID_BYTES:
        raise RunnerError(f"{label} is too long")
    return value


def finite_positive(value: Any, label: str, maximum: float = MAX_TIMEOUT_SECONDS) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise RunnerError(f"{label} must be a positive finite number")
    if value <= 0 or value > maximum:
        raise RunnerError(f"{label} is outside the supported bound")
    return float(value)


def reject_symlink(path: Path, label: str) -> None:
    if path.is_symlink():
        raise RunnerError(f"refusing symlink {label}: {path}")


def read_regular(path: Path, label: str, maximum: int) -> bytes:
    reject_symlink(path, label)
    if not path.is_file():
        raise RunnerError(f"missing {label}: {path}")
    try:
        size = path.stat().st_size
        if size > maximum:
            raise RunnerError(f"{label} is too large")
        return path.read_bytes()
    except OSError as exc:
        raise RunnerError(f"cannot read {label}: {path}") from exc


def parse_json(data: bytes, label: str) -> Any:
    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, item in pairs:
            if key in result:
                raise RunnerError(f"{label} contains a duplicate key: {key}")
            result[key] = item
        return result

    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=reject_duplicate_keys)
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, RunnerError) as exc:
        raise RunnerError(f"{label} is malformed JSON") from exc


def exact_keys(value: dict[str, Any], allowed: set[str], label: str) -> None:
    unknown = set(value) - allowed
    if unknown:
        raise RunnerError(f"{label} has unknown fields: {', '.join(sorted(unknown))}")


def load_profile(path: Path) -> dict[str, Any]:
    value = parse_json(read_regular(path, "executor profile", MAX_PROFILE_BYTES), "executor profile")
    if not isinstance(value, dict):
        raise RunnerError("executor profile must be an object")
    exact_keys(value, {"profile_id", "schema_version", "launch", "cwd", "result", "sandbox", "network", "write_scope", "timeout_seconds", "stop"}, "profile")
    if value.get("schema_version") != SCHEMA_VERSION:
        raise RunnerError("unsupported executor profile schema")
    profile_id = safe_id(value.get("profile_id"), "profile_id")

    launch = value.get("launch")
    if not isinstance(launch, dict):
        raise RunnerError("profile launch must be an object")
    exact_keys(launch, {"command", "argv", "mode", "input", "permission_mode", "dangerous", "force", "yolo"}, "launch")
    command = bounded_string(launch.get("command"), "launch.command")
    argv = launch.get("argv")
    if not isinstance(argv, list) or any(not isinstance(arg, str) or "\x00" in arg for arg in argv):
        raise RunnerError("launch.argv must be a list of NUL-free strings")
    if any(len(arg.encode("utf-8")) > MAX_ID_BYTES for arg in argv):
        raise RunnerError("launch.argv contains an oversized argument")
    if launch.get("mode") != "headless":
        raise RunnerError("only headless executor profiles are supported")
    if launch.get("input") not in {"stdin", "prompt-arg"}:
        raise RunnerError("headless profiles must declare stdin or prompt-arg input")
    permission_mode = bounded_string(launch.get("permission_mode"), "launch.permission_mode")
    for key in ("dangerous", "force", "yolo"):
        if not isinstance(launch.get(key), bool):
            raise RunnerError(f"launch.{key} must be boolean")
    if (launch["force"] or launch["yolo"]) and not launch["dangerous"]:
        raise RunnerError("force/yolo requires an explicitly dangerous profile")

    sandbox = bounded_string(value.get("sandbox"), "sandbox")
    if sandbox not in {"enabled", "disabled"}:
        raise RunnerError("sandbox must be enabled or disabled")
    network = bounded_string(value.get("network"), "network")
    if network not in {"disabled", "enabled"}:
        raise RunnerError("network must be enabled or disabled")
    write_scope = value.get("write_scope")
    if (not isinstance(write_scope, list) or not write_scope or len(write_scope) > 16
            or any(not isinstance(item, str) or not item or "\x00" in item
                   or len(item.encode("utf-8")) > MAX_ID_BYTES for item in write_scope)):
        raise RunnerError("write_scope must be a bounded non-empty list of strings")
    if sandbox == "disabled" and not launch["dangerous"]:
        raise RunnerError("disabled sandbox requires an explicitly dangerous profile")

    timeout_seconds = finite_positive(value.get("timeout_seconds"), "timeout_seconds")
    stop = value.get("stop")
    if not isinstance(stop, dict):
        raise RunnerError("profile stop must be an object")
    exact_keys(stop, {"mode", "deadline_seconds"}, "stop")
    stop_deadline = finite_positive(stop.get("deadline_seconds"), "stop.deadline_seconds", 300)
    if stop.get("mode") != "process-group":
        raise RunnerError("headless profiles must use process-group stopping")

    cwd = value.get("cwd")
    if not isinstance(cwd, dict):
        raise RunnerError("profile cwd must be an object")
    exact_keys(cwd, {"binding", "canonicalize"}, "cwd")
    if cwd != {"binding": "contract", "canonicalize": "pwd -P"}:
        raise RunnerError("profile cwd binding is unsupported")
    result = value.get("result")
    if not isinstance(result, dict):
        raise RunnerError("profile result must be an object")
    exact_keys(result, {"format", "completion", "require_marker", "marker_rule", "artifact_checks"}, "result")
    if result.get("format") not in {"text", "jsonl", "stream-json"}:
        raise RunnerError("profile result.format is unsupported")
    if result.get("completion") != "process-exit-and-marker":
        raise RunnerError("profile result must require process exit and a marker")
    if result.get("require_marker") is not True:
        raise RunnerError("profile result.require_marker must be true")
    if not isinstance(result.get("marker_rule"), str) or not result["marker_rule"]:
        raise RunnerError("profile result.marker_rule is missing")
    if not isinstance(result.get("artifact_checks"), list) or any(not isinstance(item, str) for item in result["artifact_checks"]):
        raise RunnerError("profile result.artifact_checks must be a list of strings")
    return {
        "profile_id": profile_id,
        "command": command,
        "argv": argv,
        "input": launch["input"],
        "permission_mode": permission_mode,
        "sandbox": sandbox,
        "network": network,
        "write_scope": write_scope,
        "dangerous": launch["dangerous"],
        "force": launch["force"],
        "yolo": launch["yolo"],
        "timeout_seconds": timeout_seconds,
        "stop_deadline_seconds": stop_deadline,
        "result_format": result["format"],
    }


def canonical_cwd(raw: str) -> Path:
    if not isinstance(raw, str) or not raw or "\x00" in raw:
        raise RunnerError("cwd must be a non-empty path")
    path = Path(raw).expanduser()
    if not path.is_absolute():
        raise RunnerError("cwd must be absolute")
    try:
        canonical = Path(os.path.realpath(path))
    except OSError as exc:
        raise RunnerError("cannot canonicalize cwd") from exc
    if not canonical.is_dir():
        raise RunnerError(f"cwd is not a directory: {canonical}")
    return canonical


def ensure_job_dir(raw: str, nonce: str) -> Path:
    path = Path(raw).expanduser()
    reject_symlink(path, "job directory")
    if path.name != nonce or path.parent.name != "jobs":
        raise RunnerError("job directory must be jobs/<job_nonce>")
    canonical = Path(os.path.realpath(path))
    if canonical.name != nonce or canonical.parent.name != "jobs":
        raise RunnerError("canonical job directory must be jobs/<job_nonce>")
    canonical.parent.mkdir(parents=True, exist_ok=True)
    if canonical.exists() and not canonical.is_dir():
        raise RunnerError("job directory is not a directory")
    canonical.mkdir(mode=0o700, exist_ok=True)
    return canonical


def sha256_file(path: Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while True:
            chunk = stream.read(1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            digest.update(chunk)
    return size, digest.hexdigest()


def atomic_json(path: Path, value: dict[str, Any]) -> None:
    reject_symlink(path, "result manifest")
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
    fd = -1
    temporary: Path | None = None
    try:
        fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
        temporary = Path(name)
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as stream:
            fd = -1
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    except OSError as exc:
        raise RunnerError(f"cannot write result manifest: {path}") from exc
    finally:
        if fd >= 0:
            os.close(fd)
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass


def marker_observed(path: Path, nonce: str) -> bool:
    """Find the nonce and terminal marker without loading output into memory."""
    nonce_bytes = f"<!-- CMX_JOB {nonce} -->".encode("utf-8")
    goal_bytes = b"<!-- GOAL_COMPLETE -->"
    found_nonce = False
    carry = b""
    with path.open("rb") as stream:
        while True:
            chunk = stream.read(1024 * 1024)
            if not chunk:
                break
            data = carry + chunk
            if not found_nonce:
                position = data.find(nonce_bytes)
                if position >= 0:
                    found_nonce = True
                    data = data[position + len(nonce_bytes):]
                else:
                    carry = data[-(len(nonce_bytes) - 1):]
                    continue
            if goal_bytes in data:
                return True
            # Once the nonce has been observed, all later chunks are part of
            # the candidate output. Keep a short suffix so a marker split
            # across two writes is still recognized.
            carry = data[-(len(goal_bytes) - 1):]
    return False


def mirror_stream(source: Any, destination: Any, display: Any) -> None:
    display_enabled = True
    try:
        while True:
            try:
                chunk = source.read(64 * 1024)
            except (OSError, ValueError):
                return
            if not chunk:
                return
            destination.write(chunk)
            destination.flush()
            if display_enabled:
                try:
                    display.write(chunk)
                    display.flush()
                except (BrokenPipeError, OSError):
                    # Capturing the raw stream remains authoritative even when
                    # the visible cmux consumer closes unexpectedly.
                    display_enabled = False
    finally:
        source.close()


def terminate_group(process: subprocess.Popen[bytes], deadline: float) -> bool:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return False
    except OSError:
        try:
            process.terminate()
        except OSError:
            pass
    try:
        process.wait(timeout=max(0.01, deadline))
        return False
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError:
            try:
                process.kill()
            except OSError:
                pass
        process.wait()
        return True


def run(args: argparse.Namespace) -> int:
    nonce = safe_id(args.job_nonce, "job_nonce")
    workspace = safe_id(args.workspace, "workspace")
    surface = safe_id(args.surface, "surface")
    profile_path = Path(args.profile).expanduser()
    profile = load_profile(profile_path)
    cwd = canonical_cwd(args.cwd)
    requested_timeout = (
        finite_positive(args.timeout_seconds, "job timeout_seconds")
        if args.timeout_seconds is not None
        else profile["timeout_seconds"]
    )
    timeout_seconds = min(profile["timeout_seconds"], requested_timeout)
    task_path = Path(args.task_file).expanduser()
    task_bytes = read_regular(task_path, "task file", MAX_TASK_BYTES)
    if profile["input"] == "prompt-arg" and len(task_bytes) > MAX_PROMPT_ARG_BYTES:
        raise RunnerError("task file is too large for prompt-arg input")
    try:
        task_text = task_bytes.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise RunnerError("task file must be UTF-8") from exc
    if profile["input"] == "prompt-arg" and "\x00" in task_text:
        raise RunnerError("task file contains NUL, which cannot be an argument")
    job_dir = ensure_job_dir(args.job_dir, nonce)
    result_path = job_dir / "result.json"
    stdout_path = job_dir / "stdout.log"
    stderr_path = job_dir / "stderr.log"
    for path, label in ((result_path, "result manifest"), (stdout_path, "stdout capture"), (stderr_path, "stderr capture")):
        reject_symlink(path, label)
        if path.exists():
            raise RunnerError(f"refusing to overwrite existing {label}: {path}")

    command = profile["command"]
    executable = shutil.which(command)
    if executable is None:
        raise RunnerError(f"executor command is unavailable: {command}")
    started_ns = time.time_ns()
    task_hash = hashlib.sha256(task_bytes).hexdigest()
    metadata: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "job_nonce": nonce,
        "profile_id": profile["profile_id"],
        "workspace": workspace,
        "surface": surface,
        "cwd": str(cwd),
        "status": "starting",
        "started_at_ns": started_ns,
        "task_sha256": task_hash,
        "stdout_path": str(stdout_path),
        "stderr_path": str(stderr_path),
        "result_path": str(result_path),
        "permission_mode": profile["permission_mode"],
        "input": profile["input"],
        "sandbox": profile["sandbox"],
        "network": profile["network"],
        "write_scope": profile["write_scope"],
        "dangerous": profile["dangerous"],
        "force": profile["force"],
        "yolo": profile["yolo"],
        "executable": executable,
        "result_format": profile["result_format"],
        "timeout_seconds": timeout_seconds,
        "command_sha256": hashlib.sha256((command + "\0" + "\0".join(profile["argv"])).encode("utf-8")).hexdigest(),
    }
    atomic_json(result_path, metadata)

    env = os.environ.copy()
    env.update(
        {
            "CMUX_AGENT_JOB_NONCE": nonce,
            "CMUX_AGENT_JOB_DIR": str(job_dir),
            "CMUX_AGENT_WORKSPACE": workspace,
            "CMUX_AGENT_SURFACE": surface,
            "CMUX_AGENT_CWD": str(cwd),
            "CMUX_AGENT_INPUT_MODE": profile["input"],
        }
    )
    command_argv = [executable, *profile["argv"]]
    if profile["input"] == "prompt-arg":
        command_argv.append(task_text)
    process: subprocess.Popen[bytes] | None = None
    task_handle = None
    stdout_handle = None
    stderr_handle = None
    output_threads: list[threading.Thread] = []
    timed_out = False
    cancelled = False
    killed = False
    return_code: int | None = None
    try:
        stdout_handle = stdout_path.open("xb")
        stderr_handle = stderr_path.open("xb")
        task_handle = task_path.open("rb")
        process = subprocess.Popen(
            command_argv,
            cwd=str(cwd),
            stdin=task_handle if profile["input"] == "stdin" else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            start_new_session=True,
        )
        assert process.stdout is not None and process.stderr is not None
        output_threads = [
            threading.Thread(target=mirror_stream, args=(process.stdout, stdout_handle, sys.stdout.buffer), daemon=True),
            threading.Thread(target=mirror_stream, args=(process.stderr, stderr_handle, sys.stderr.buffer), daemon=True),
        ]
        for thread in output_threads:
            thread.start()
        metadata["pid"] = process.pid
        metadata["status"] = "running"
        metadata["output_mirrored"] = True
        atomic_json(result_path, metadata)
        try:
            return_code = process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            killed = terminate_group(process, profile["stop_deadline_seconds"])
            return_code = process.returncode
        except KeyboardInterrupt:
            cancelled = True
            killed = terminate_group(process, profile["stop_deadline_seconds"])
            return_code = process.returncode
    except KeyboardInterrupt:
        cancelled = True
        if process is None:
            metadata["status"] = "cancelled"
            metadata["cancelled"] = True
            metadata["finished_at_ns"] = time.time_ns()
            atomic_json(result_path, metadata)
            return 130
        killed = terminate_group(process, profile["stop_deadline_seconds"])
        return_code = process.returncode
    except (OSError, ValueError) as exc:
        metadata["status"] = "failed"
        metadata["error"] = error_text(exc)
        metadata["finished_at_ns"] = time.time_ns()
        atomic_json(result_path, metadata)
        return 127
    finally:
        if task_handle is not None:
            task_handle.close()
        for thread in output_threads:
            thread.join(timeout=5)
        if stdout_handle is not None:
            stdout_handle.close()
        if stderr_handle is not None:
            stderr_handle.close()

    assert process is not None
    finished_ns = time.time_ns()
    metadata["finished_at_ns"] = finished_ns
    metadata["duration_ms"] = round((finished_ns - started_ns) / 1_000_000, 3)
    metadata["exit_code"] = return_code
    metadata["timed_out"] = timed_out
    metadata["cancelled"] = cancelled
    metadata["force_killed"] = killed
    stdout_size, stdout_hash = sha256_file(stdout_path)
    stderr_size, stderr_hash = sha256_file(stderr_path)
    metadata["stdout_size"] = stdout_size
    metadata["stdout_sha256"] = stdout_hash
    metadata["stderr_size"] = stderr_size
    metadata["stderr_sha256"] = stderr_hash
    marker_found = marker_observed(stdout_path, nonce)
    metadata["marker_observed"] = marker_found
    if timed_out:
        metadata["status"] = "timed_out"
    elif cancelled:
        metadata["status"] = "cancelled"
    elif return_code == 0 and marker_found:
        metadata["status"] = "completed"
    else:
        metadata["status"] = "failed"
        if return_code == 0 and not marker_found:
            metadata["error"] = "required completion marker was not observed"
    atomic_json(result_path, metadata)
    if timed_out:
        return 124
    if cancelled:
        return 130
    if return_code is None or (return_code == 0 and not marker_found):
        return 1
    return return_code if return_code >= 0 else 128 + (-return_code)


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--profile", required=True, help="validated machine-local profile JSON")
    value.add_argument("--task-file", required=True, help="UTF-8 task input file")
    value.add_argument("--job-dir", required=True, help="runtime jobs/<job_nonce> directory")
    value.add_argument("--job-nonce", required=True)
    value.add_argument("--workspace", required=True)
    value.add_argument("--surface", required=True)
    value.add_argument("--cwd", required=True)
    value.add_argument("--timeout-seconds", type=float, default=None)
    return value


def main() -> int:
    try:
        return run(parser().parse_args())
    except RunnerError as exc:
        print(f"cmux-agent-run: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("cmux-agent-run: cancelled", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
