#!/usr/bin/env bash
# Install or check the explicit headless cmux-agent profiles and runner.
#
# The default is a read-only plan. Mutations require --apply and confirmation;
# --check never writes. This command does not install hooks or alter shell
# startup files.
set -euo pipefail

repo=$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
profile=""
mode="plan"

usage() {
  cat <<'EOF'
Usage: tools/cmux-agent-setup.sh --profile cursor|agy|both [--apply|--check]

Default mode prints a read-only plan. --apply asks before writing. --check is
read-only and exits non-zero until the selected setup is ready.

--profile cursor|agy|both  Required explicit executor selection.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || { echo "setup: --profile requires cursor, agy, or both" >&2; exit 2; }
      [[ -z "$profile" ]] || { echo "setup: --profile may be supplied once" >&2; exit 2; }
      profile=$2
      shift 2
      ;;
    --profile=*)
      [[ -z "$profile" ]] || { echo "setup: --profile may be supplied once" >&2; exit 2; }
      profile=${1#--profile=}
      shift
      ;;
    --apply)
      [[ "$mode" == plan ]] || { echo "setup: --apply and --check are mutually exclusive" >&2; exit 2; }
      mode=apply
      shift
      ;;
    --check)
      [[ "$mode" == plan ]] || { echo "setup: --apply and --check are mutually exclusive" >&2; exit 2; }
      mode=check
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "setup: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$profile" ]] || { echo "setup: explicit --profile cursor|agy|both is required" >&2; exit 2; }
case "$profile" in
  cursor|agy|both) ;;
  *) echo "setup: unsupported profile '$profile'; choose cursor, agy, or both" >&2; exit 2 ;;
esac

python_script=$(mktemp "${TMPDIR:-/tmp}/cmux-agent-setup.XXXXXX.py")
trap 'rm -f -- "$python_script"' EXIT
cat >"$python_script" <<'PY'
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile


class SetupError(Exception):
    pass


repo = Path(sys.argv[1]).absolute()
selected = sys.argv[2]
mode = sys.argv[3]


def absolute_path(value: str) -> Path:
    return Path(os.path.abspath(os.path.expanduser(os.path.expandvars(value))))


home = absolute_path(os.environ.get("CMUX_AGENT_HOME") or os.environ["HOME"])
config = absolute_path(os.environ.get("CMUX_AGENT_CONFIG") or str(home / ".config" / "cmux-agent"))
profile_dir = absolute_path(os.environ.get("CMUX_AGENT_PROFILE_DIR") or str(config / "profiles"))
runtime = absolute_path(os.environ.get("CMUX_AGENT_RUNTIME") or str(home / ".local" / "state" / "cmux-agent"))
bin_dir = absolute_path(os.environ.get("CMUX_AGENT_BIN") or str(config / "bin"))


def wants(name: str) -> bool:
    return selected in {name, "both"}


def mode_bits(path: Path, fallback: int = 0o644) -> int:
    try:
        return stat.S_IMODE(path.stat().st_mode)
    except OSError:
        return fallback


def reject_parent_links(path: Path) -> None:
    current = path.parent
    while True:
        if current.exists():
            if current.is_symlink():
                raise SetupError(f"unsafe symlink destination parent: {current}")
            if not current.is_dir():
                raise SetupError(f"non-directory destination parent: {current}")
            break
        if current == current.parent:
            break
        current = current.parent


def reject_file_target(path: Path) -> None:
    reject_parent_links(path)
    if path.is_symlink():
        raise SetupError(f"refusing symlink target: {path}")
    if path.exists() and not path.is_file():
        raise SetupError(f"refusing non-file target: {path}")


def reject_directory_target(path: Path) -> None:
    reject_parent_links(path / ".placeholder")
    if path.is_symlink():
        raise SetupError(f"refusing symlink directory: {path}")
    if path.exists() and not path.is_dir():
        raise SetupError(f"refusing non-directory destination: {path}")


def read_source(path: Path) -> bytes:
    if path.is_symlink() or not path.is_file():
        raise SetupError(f"missing or unsafe repository source: {path}")
    try:
        return path.read_bytes()
    except OSError as exc:
        raise SetupError(f"cannot read repository source: {path}") from exc


def validate_profile(data: bytes, path: Path, profile_name: str) -> bytes:
    try:
        value = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SetupError(f"malformed profile source: {path}") from exc
    if not isinstance(value, dict) or value.get("profile_id") != profile_name:
        raise SetupError(f"profile source has the wrong profile_id: {path}")
    launch = value.get("launch")
    if not isinstance(launch, dict) or launch.get("mode") != "headless" or launch.get("input") not in {"stdin", "prompt-arg"}:
        raise SetupError(f"profile is not a supported headless input profile: {path}")
    if not isinstance(launch.get("command"), str) or not launch["command"]:
        raise SetupError(f"profile command is missing: {path}")
    if not isinstance(launch.get("argv"), list) or any(not isinstance(item, str) for item in launch["argv"]):
        raise SetupError(f"profile argv is malformed: {path}")
    if value.get("sandbox") not in {"enabled", "disabled"}:
        raise SetupError(f"profile sandbox declaration is missing: {path}")
    if value.get("network") not in {"enabled", "disabled"}:
        raise SetupError(f"profile network declaration is missing: {path}")
    write_scope = value.get("write_scope")
    if (not isinstance(write_scope, list) or not write_scope
            or any(not isinstance(item, str) or not item for item in write_scope)):
        raise SetupError(f"profile write_scope declaration is missing: {path}")
    return data


class DirectoryItem:
    def __init__(self, label: str, target: Path):
        self.label = label
        self.target = target
        reject_directory_target(target)
        self.state = "present" if target.exists() else "missing"

    @property
    def needs_write(self) -> bool:
        return self.state == "missing"


class FileItem:
    def __init__(self, label: str, target: Path, data: bytes, source_mode: int):
        self.label = label
        self.target = target
        self.data = data
        self.source_mode = source_mode
        reject_file_target(target)
        if not target.exists():
            self.state = "missing"
        elif target.read_bytes() != data:
            self.state = "different"
        elif mode_bits(target) != source_mode:
            self.state = "mode-different"
        else:
            self.state = "unchanged"

    @property
    def needs_write(self) -> bool:
        return self.state != "unchanged"


sources = {
    "runner": repo / "tools" / "cmux-agent-run.py",
    "waiter": repo / "tools" / "cmux-agent-wait.py",
    "cursor": repo / "adapters" / "cursor" / "executor-profile.cursor.json",
    "agy": repo / "adapters" / "agy" / "executor-profile.agy.json",
}
source_data: dict[str, bytes] = {}
for key in ("runner", "waiter", "cursor" if wants("cursor") else None, "agy" if wants("agy") else None):
    if key:
        source_data[key] = read_source(sources[key])
if wants("cursor"):
    source_data["cursor"] = validate_profile(source_data["cursor"], sources["cursor"], "cursor")
if wants("agy"):
    source_data["agy"] = validate_profile(source_data["agy"], sources["agy"], "agy")


def profile_timeout(profile_name: str) -> int | float:
    value = json.loads(source_data[profile_name].decode("utf-8"))
    timeout = value.get("timeout_seconds")
    if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or timeout <= 0:
        raise SetupError(f"profile timeout is invalid: {profile_name}")
    return timeout


directories = [
    DirectoryItem("profile directory", profile_dir),
    DirectoryItem("runtime directory", runtime),
    DirectoryItem("runtime jobs directory", runtime / "jobs"),
    DirectoryItem("runner bin directory", bin_dir),
]
items: list[FileItem] = [
    FileItem("headless runner", bin_dir / "cmux-agent-run.py", source_data["runner"], mode_bits(sources["runner"])),
    FileItem("result waiter", bin_dir / "cmux-agent-wait.py", source_data["waiter"], mode_bits(sources["waiter"])),
]
if wants("cursor"):
    items.append(FileItem("Cursor headless profile", profile_dir / "cursor.json", source_data["cursor"], mode_bits(sources["cursor"])))
if wants("agy"):
    items.append(FileItem("agy headless profile", profile_dir / "agy.json", source_data["agy"], mode_bits(sources["agy"])))
agent_ready = shutil.which("agent") is not None
agy_ready = shutil.which("agy") is not None


def print_plan() -> None:
    print(f"Profile selection: {selected} (explicit; no CLI auto-detection)")
    print("Mode: " + ("read-only check" if mode == "check" else "read-only plan" if mode == "plan" else "apply"))
    for item in directories:
        print(f"  {'keep' if item.state == 'present' else 'create during --apply'}: {item.label}: {item.target}")
    for item in items:
        if item.state == "unchanged":
            action = "skip byte-identical"
        elif item.state == "missing":
            action = "create during --apply"
        elif item.state == "mode-different":
            action = "repair mode after confirmation"
        else:
            action = "replace only after confirmation"
        print(f"  {action}: {item.label}: {item.target}")
    for profile_name in ("cursor", "agy"):
        if wants(profile_name):
            print(
                f"  {profile_name} profile config: {profile_dir / (profile_name + '.json')} "
                f"(timeout_seconds={profile_timeout(profile_name)})"
            )
    if wants("cursor"):
        print(f"  preflight Cursor executable: {'ready' if agent_ready else 'missing'} ({shutil.which('agent') or 'not found'})")
    if wants("agy"):
        print(f"  preflight agy executable: {'ready' if agy_ready else 'missing'} ({shutil.which('agy') or 'not found'})")
    print("No Cursor/agy hooks, transcripts, shell startup files, credentials, or timeline files are installed.")


def atomic_write(path: Path, data: bytes, mode_value: int) -> None:
    reject_file_target(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = -1
    temporary: Path | None = None
    try:
        fd, name = tempfile.mkstemp(prefix=f".{path.name}.cmux-agent-setup-", dir=str(path.parent))
        temporary = Path(name)
        os.fchmod(fd, mode_value)
        with os.fdopen(fd, "wb") as stream:
            fd = -1
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    except OSError as exc:
        raise SetupError(f"cannot write setup target: {path}") from exc
    finally:
        if fd >= 0:
            os.close(fd)
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass


def ask(question: str) -> bool:
    print(question, end="", flush=True)
    lines = os.read(0, 4096).splitlines()
    first_line = lines[0] if lines else b""
    return first_line.decode("utf-8", "replace").strip().lower() in {"y", "yes"}


def apply_setup() -> int:
    if not any(item.needs_write for item in directories + items):
        print("Already ready; no changes required.")
        return 0
    print_plan()
    if not ask("Apply exactly the changes above? (y/N) "):
        print("Aborted; nothing was changed.")
        return 1
    skipped = False
    for directory in directories:
        if directory.needs_write:
            reject_directory_target(directory.target)
            directory.target.mkdir(parents=True, exist_ok=True)
            print(f"Created {directory.label}: {directory.target}")
    for item in items:
        if item.state == "unchanged":
            continue
        if item.state in {"different", "mode-different"} and not ask(f"Replace differing {item.label} at {item.target}? (y/N) "):
            print(f"Skipped differing target: {item.target}")
            skipped = True
            continue
        atomic_write(item.target, item.data, item.source_mode)
        print(f"Installed {item.label}: {item.target}")
    if skipped:
        print("Setup incomplete: one or more differing targets were left unchanged.")
        return 1
    print("Setup applied. Executor selection remains explicit per job or environment.")
    return 0


def check_setup() -> int:
    ready = True
    print(f"CHECK profile={selected} (read-only)")
    for directory in directories:
        if directory.state == "present":
            print(f"  READY directory: {directory.target}")
        else:
            print(f"  MISSING directory: {directory.target}")
            ready = False
    for item in items:
        if item.state == "unchanged":
            if item.target.name.endswith(".py") and not os.access(item.target, os.X_OK):
                print(f"  STALE non-executable target: {item.target}")
                ready = False
            else:
                print(f"  READY file: {item.target}")
        else:
            print(f"  STALE or missing file: {item.target}")
            ready = False
    if wants("cursor") and not agent_ready:
        print("  MISSING preflight executable: agent")
        ready = False
    if wants("agy") and not agy_ready:
        print("  MISSING preflight executable: agy")
        ready = False
    if ready:
        print("CHECK READY: selected setup is complete.")
        return 0
    print("CHECK NOT READY: no files or settings were changed.")
    return 1


try:
    if mode == "check":
        raise SystemExit(check_setup())
    if mode == "apply":
        raise SystemExit(apply_setup())
    print_plan()
except SetupError as exc:
    print(f"setup: {exc}", file=sys.stderr)
    raise SystemExit(2)
except (OSError, ValueError) as exc:
    print(f"setup: operation failed safely: {exc}", file=sys.stderr)
    raise SystemExit(2)
PY
python3 "$python_script" "$repo" "$profile" "$mode"
