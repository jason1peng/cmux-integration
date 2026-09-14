#!/usr/bin/env bash
# Install or check the explicitly selected cmux executor profile templates.
#
# The default is a read-only plan.  Mutations require --apply and a second
# confirmation after the plan is displayed.  --check never writes anything.
# This command deliberately does not select an executor or edit shell startup
# files; direct Pi prompting remains the default.
set -euo pipefail

repo=$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
profile=""
mode="plan"
advisor=0
with_pi=0

usage() {
  cat <<'EOF'
Usage: tools/cmux-agent-setup.sh --profile cursor|agy|both [--apply|--check] [--advisor] [--with-pi]

Default mode prints a read-only plan.  --apply asks before writing.  --check
is read-only and exits non-zero until the selected setup is ready.

--profile cursor|agy|both  Required explicit executor selection.
--advisor                   With Cursor, install the optional advisor and its
                            authoritative command-policy helper.
--with-pi                   Install the global Pi agent and orchestration skill.
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
    --advisor)
      advisor=1
      shift
      ;;
    --with-pi)
      with_pi=1
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
if [[ "$advisor" -eq 1 && "$profile" == agy ]]; then
  echo "setup: --advisor is only valid when cursor is selected" >&2
  exit 2
fi

python_script=$(mktemp "${TMPDIR:-/tmp}/cmux-agent-setup.XXXXXX.py")
trap 'rm -f -- "$python_script"' EXIT
cat >"$python_script" <<'PY'
from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
from typing import Any


class SetupError(Exception):
    """A refusal that must happen before any setup mutation."""


repo = Path(sys.argv[1]).absolute()
selected = sys.argv[2]
mode = sys.argv[3]
advisor_requested = sys.argv[4] == "1"
with_pi = sys.argv[5] == "1"


def absolute_path(value: str) -> Path:
    # Do not call resolve(): resolving a destination can silently follow a
    # user-provided symlink.  Existing target symlinks are rejected below.
    return Path(os.path.abspath(os.path.expanduser(os.path.expandvars(value))))


home = absolute_path(os.environ.get("CMUX_AGENT_HOME") or os.environ["HOME"])
config = absolute_path(
    os.environ.get("CMUX_AGENT_CONFIG") or str(home / ".config" / "cmux-agent")
)
profile_dir = absolute_path(
    os.environ.get("CMUX_AGENT_PROFILE_DIR") or str(config / "profiles")
)
runtime = absolute_path(
    os.environ.get("CMUX_AGENT_RUNTIME") or str(home / ".local" / "state" / "cmux-agent")
)
# Cursor's documented default is config/bin; agy's existing installer keeps
# its documented ~/bin destination.  CMUX_AGENT_BIN explicitly overrides both.
bin_override = os.environ.get("CMUX_AGENT_BIN")
cursor_bin = absolute_path(bin_override or str(config / "bin"))
agy_bin = absolute_path(bin_override or str(home / "bin"))
cursor_home = home / ".cursor"
cursor_hooks_config = absolute_path(
    os.environ.get("CMUX_AGENT_CURSOR_HOOKS_CONFIG")
    or str(cursor_home / "hooks.json")
)
agy_hooks_config = absolute_path(
    os.environ.get("CMUX_AGENT_HOOKS_CONFIG")
    or str(home / ".gemini" / "config" / "hooks.json")
)


def wants(name: str) -> bool:
    return selected in (name, "both")


def mode_bits(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def check_parent_links(path: Path) -> None:
    """Reject existing symlink parents so a write cannot escape its plan."""
    current = path.parent
    while True:
        if current.exists() or current.is_symlink():
            if current.is_symlink():
                raise SetupError(f"unsafe symlink destination parent: {current}")
            if not current.is_dir():
                raise SetupError(f"non-directory destination parent: {current}")
            break
        if current == current.parent:
            break
        current = current.parent


def reject_target_kind(path: Path) -> None:
    check_parent_links(path)
    if path.is_symlink():
        raise SetupError(f"refusing unsafe symlink target: {path}")
    if path.exists() and not path.is_file():
        raise SetupError(f"refusing non-file target: {path}")


def reject_directory_kind(path: Path) -> None:
    check_parent_links(path / ".placeholder")
    if path.is_symlink():
        raise SetupError(f"refusing unsafe symlink directory: {path}")
    if path.exists() and not path.is_dir():
        raise SetupError(f"refusing non-directory destination: {path}")


def ensure_source(path: Path) -> bytes:
    if path.is_symlink() or not path.is_file():
        raise SetupError(f"missing or unsafe repository template: {path}")
    try:
        return path.read_bytes()
    except OSError as exc:
        raise SetupError(f"cannot read repository template: {path}") from exc


def load_json(path: Path, label: str) -> Any:
    try:
        with path.open(encoding="utf-8") as stream:
            return json.load(stream)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise SetupError(f"malformed {label}; refusing to edit: {path}") from exc


def json_bytes(value: Any) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def source_mode(path: Path, fallback: int = 0o644) -> int:
    try:
        return mode_bits(path)
    except OSError:
        return fallback


class FileItem:
    def __init__(self, label: str, target: Path, data: bytes, mode_bits_value: int):
        self.label = label
        self.target = target
        self.data = data
        self.mode = mode_bits_value
        self.state = ""
        reject_target_kind(target)
        if target.exists():
            try:
                existing = target.read_bytes()
            except OSError as exc:
                raise SetupError(f"cannot read existing target: {target}") from exc
            if existing != data:
                self.state = "different"
            else:
                self.state = "unchanged" if mode_bits(target) == mode_bits_value else "mode-different"
        else:
            self.state = "missing"

    @property
    def needs_write(self) -> bool:
        return self.state != "unchanged"


class DirectoryItem:
    def __init__(self, label: str, target: Path):
        self.label = label
        self.target = target
        reject_directory_kind(target)
        self.state = "present" if target.exists() else "missing"

    @property
    def needs_create(self) -> bool:
        return self.state == "missing"


class HookPlan:
    def __init__(self, label: str, target: Path, desired: dict[str, Any]):
        self.label = label
        self.target = target
        self.desired = desired
        self.current: Any = None
        self.state = "missing"
        reject_target_kind(target)
        if target.exists():
            self.current = load_json(target, label)
            self.state = "unchanged"
            self.merged = self._merge()
            if self.merged != self.current:
                self.state = "different"
        else:
            self.merged = copy.deepcopy(desired)

    def _merge(self) -> dict[str, Any]:
        if not isinstance(self.current, dict):
            raise SetupError(f"malformed {self.label}; expected a JSON object: {self.target}")
        hooks = self.current.get("hooks")
        if not isinstance(hooks, dict):
            raise SetupError(f"malformed {self.label}; expected a hooks object: {self.target}")
        # Validate every existing event before constructing a merged config.
        # Unrelated entries are preserved verbatim, but malformed entries must
        # not be allowed to hide in an event that this setup does not add to.
        for event, existing_entries in hooks.items():
            if not isinstance(event, str) or not event:
                raise SetupError(f"malformed {self.label}; hook event name is invalid: {self.target}")
            if not isinstance(existing_entries, list):
                raise SetupError(f"malformed {self.label}; expected an array for {event}: {self.target}")
            for existing in existing_entries:
                if not isinstance(existing, dict):
                    raise SetupError(f"malformed {self.label}; hook entry for {event} is not an object: {self.target}")
                command = existing.get("command")
                if not isinstance(command, str) or not command.strip():
                    raise SetupError(f"malformed {self.label}; hook entry for {event} has no command: {self.target}")
                timeout = existing.get("timeout")
                if timeout is not None and (isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or timeout <= 0):
                    raise SetupError(f"malformed {self.label}; hook entry for {event} has an invalid timeout: {self.target}")
        merged = copy.deepcopy(self.current)
        merged_hooks = merged["hooks"]
        for event, wanted_entries in self.desired["hooks"].items():
            existing_entries = merged_hooks.get(event, [])
            if not isinstance(existing_entries, list):
                raise SetupError(f"malformed {self.label}; expected an array for {event}: {self.target}")
            for existing in existing_entries:
                if not isinstance(existing, dict):
                    raise SetupError(f"malformed {self.label}; hook entry for {event} is not an object: {self.target}")
            for wanted in wanted_entries:
                wanted_command = wanted.get("command")
                wanted_name = Path(str(wanted_command)).name
                matching_commands = [
                    existing for existing in existing_entries
                    if isinstance(existing.get("command"), str)
                    and Path(existing["command"]).name == wanted_name
                ]
                if len(matching_commands) > 1:
                    raise SetupError(
                        f"conflicting duplicate {self.label} entries for {event}: {self.target}"
                    )
                for existing in existing_entries:
                    existing_command = existing.get("command")
                    if not isinstance(existing_command, str):
                        continue
                    if existing_command == wanted_command and existing != wanted:
                        raise SetupError(
                            f"conflicting existing {self.label} entry for {event}: {self.target}"
                        )
                    # A differently rooted or argument-bearing copy of one of
                    # our adapters is not unrelated; reject it rather than
                    # silently registering two ambiguous callbacks.
                    if Path(existing_command).name == wanted_name and existing_command != wanted_command:
                        raise SetupError(
                            f"conflicting existing {self.label} command for {event}: {self.target}"
                        )
                if wanted not in existing_entries:
                    existing_entries.append(copy.deepcopy(wanted))
            merged_hooks[event] = existing_entries
        return merged

    @property
    def merged_bytes(self) -> bytes:
        return json_bytes(self.merged)

    @property
    def needs_write(self) -> bool:
        return self.state != "unchanged"


def read_profile(path: Path) -> dict[str, Any]:
    value = load_json(path, f"profile template {path}")
    if not isinstance(value, dict) or not value.get("profile_id"):
        raise SetupError(f"invalid profile template: {path}")
    return value


def materialize_value(value: Any, replacements: dict[str, str]) -> Any:
    if isinstance(value, dict):
        return {key: materialize_value(item, replacements) for key, item in value.items()}
    if isinstance(value, list):
        return [materialize_value(item, replacements) for item in value]
    if isinstance(value, str):
        for placeholder, replacement in replacements.items():
            value = value.replace(placeholder, replacement)
    return value


def materialize_profile(path: Path, profile_name: str) -> bytes:
    """Bind a copied profile to the exact destinations selected for this run."""
    profile = read_profile(path)
    bin_root = cursor_bin if profile_name == "cursor" else agy_bin
    replacements = {
        "${HOME}": str(home),
        "${CMUX_AGENT_CONFIG}": str(config),
        "${CMUX_AGENT_RUNTIME}": str(runtime),
        "${CMUX_AGENT_BIN}": str(bin_root),
    }
    profile = materialize_value(profile, replacements)
    if profile_name == "cursor":
        watcher = profile.get("watcher")
        lifecycle = profile.get("lifecycle")
        if not isinstance(watcher, dict) or not isinstance(lifecycle, dict):
            raise SetupError(f"invalid Cursor profile template: {path}")
        watcher["command"] = str(cursor_bin / "cursor-result-watcher.sh")
        advisor = watcher.get("advisor")
        if not isinstance(advisor, dict):
            raise SetupError(f"invalid Cursor advisor profile template: {path}")
        advisor["command"] = str(cursor_bin / "cursor-advisor.sh")
        advisor["command_policy"] = str(cursor_bin / "cmux-agent-command-policy.py")
        lifecycle["hook_config"] = str(cursor_hooks_config)
    else:
        launch = profile.get("launch")
        lifecycle = profile.get("lifecycle")
        if not isinstance(launch, dict) or not isinstance(lifecycle, dict):
            raise SetupError(f"invalid agy profile template: {path}")
        launch["command"] = str(agy_bin / "agy-with-permissions")
        lifecycle["hook_config"] = str(agy_hooks_config)
        lifecycle["adapter"] = str(agy_bin / "agy-hook-notify.sh")
    return json_bytes(profile)


# Validate repository sources before any target inspection or mutation.
cursor_profile_source = repo / "adapters" / "cursor" / "executor-profile.cursor.json"
cursor_watcher_source = repo / "adapters" / "cursor" / "cursor-result-watcher.sh"
cursor_bridge_source = repo / "adapters" / "cursor" / "cursor-transcript-bridge.sh"
cursor_stop_source = repo / "adapters" / "cursor" / "cursor-stop-notify.sh"
cursor_advisor_source = repo / "adapters" / "cursor" / "cursor-advisor.sh"
command_policy_source = repo / "tools" / "cmux-agent-command-policy.py"
cursor_fragment_source = repo / "adapters" / "cursor" / "cursor-hooks.json"
agy_profile_source = repo / "adapters" / "agy" / "executor-profile.agy.json"
agy_wrapper_source = repo / "adapters" / "agy" / "agy-with-permissions.sh"
agy_adapter_source = repo / "adapters" / "agy" / "agy-hook-notify.sh"
agy_registration_source = repo / "adapters" / "agy" / "agy-result-hook.hooks.json"
agy_installer = repo / "adapters" / "agy" / "agy-install.sh"
pi_agent_source = repo / ".pi" / "agents" / "cmux-agent.md"
pi_skill_source = repo / "skills" / "cmux-agent-orchestration" / "SKILL.md"

source_data: dict[Path, bytes] = {}
required_sources = [
    (cursor_profile_source if wants("cursor") else None),
    (cursor_watcher_source if wants("cursor") else None),
    (cursor_bridge_source if wants("cursor") else None),
    (cursor_stop_source if wants("cursor") else None),
    (cursor_advisor_source if wants("cursor") and advisor_requested else None),
    (command_policy_source if wants("cursor") and advisor_requested else None),
    (cursor_fragment_source if wants("cursor") else None),
    (agy_profile_source if wants("agy") else None),
    (agy_wrapper_source if wants("agy") else None),
    (agy_adapter_source if wants("agy") else None),
    (agy_registration_source if wants("agy") else None),
    (agy_installer if wants("agy") else None),
    (pi_agent_source if with_pi else None),
    (pi_skill_source if with_pi else None),
]
for source in required_sources:
    if source is not None:
        source_data[source] = ensure_source(source)
cursor_profile_data: bytes | None = None
agy_profile_data: bytes | None = None
if wants("cursor"):
    cursor_profile_data = materialize_profile(cursor_profile_source, "cursor")
if wants("agy"):
    agy_profile_data = materialize_profile(agy_profile_source, "agy")


def make_user_hooks() -> dict[str, Any]:
    fragment = load_json(cursor_fragment_source, "Cursor hook fragment")
    if not isinstance(fragment, dict) or not isinstance(fragment.get("hooks"), dict):
        raise SetupError(f"malformed Cursor hook fragment: {cursor_fragment_source}")
    result: dict[str, Any] = {"version": fragment.get("version", 1), "hooks": {}}
    for event, entries in fragment["hooks"].items():
        if not isinstance(entries, list):
            raise SetupError(f"malformed Cursor hook fragment event: {event}")
        converted: list[Any] = []
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get("command"), str):
                raise SetupError(f"malformed Cursor hook fragment entry: {event}")
            command = entry["command"]
            if not command.startswith(".cursor/hooks/"):
                raise SetupError(f"unexpected Cursor project hook command: {event}")
            user_entry = copy.deepcopy(entry)
            user_entry["command"] = command[len(".cursor/") :]
            converted.append(user_entry)
        result["hooks"][event] = converted
    return result


directories: list[DirectoryItem] = []
items: list[FileItem] = []
hook_plans: list[HookPlan] = []
agy_target_states: list[tuple[str, Path, str]] = []
agy_registration_ready = False
agy_delegate_needed = False


def add_directory(label: str, path: Path) -> None:
    if not any(item.target == path for item in directories):
        directories.append(DirectoryItem(label, path))


def add_file(label: str, target: Path, source: Path, data: bytes | None = None) -> None:
    if data is None:
        data = source_data[source]
    item = FileItem(label, target, data, source_mode(source))
    # A shared override can intentionally make two labels share a destination;
    # require byte-identical content rather than silently changing it twice.
    for existing in items:
        if existing.target == target:
            if existing.data != item.data:
                raise SetupError(f"destination has incompatible selected templates: {target}")
            return
    items.append(item)


# Common profile/runtime directories are created only by --apply.
add_directory("profile directory", profile_dir)
add_directory("runtime directory", runtime)
add_directory("runtime jobs directory", runtime / "jobs")
add_directory("runtime events directory", runtime / "events")

if wants("cursor"):
    add_directory("Cursor adapter bin directory", cursor_bin)
    add_directory("Cursor home directory", cursor_home)
    add_directory("Cursor user hooks directory", cursor_home / "hooks")
    add_file("Cursor profile", profile_dir / "cursor.json", cursor_profile_source, cursor_profile_data)
    add_file("Cursor deterministic watcher", cursor_bin / "cursor-result-watcher.sh", cursor_watcher_source)
    add_file("Cursor transcript bridge", cursor_home / "hooks" / "cursor-transcript-bridge.sh", cursor_bridge_source)
    add_file("Cursor stop adapter", cursor_home / "hooks" / "cursor-stop-notify.sh", cursor_stop_source)
    if advisor_requested:
        add_file("Cursor advisor", cursor_bin / "cursor-advisor.sh", cursor_advisor_source)
        add_file("Cursor command-policy helper", cursor_bin / "cmux-agent-command-policy.py", command_policy_source)
    hook_plans.append(HookPlan("Cursor user hook config", cursor_hooks_config, make_user_hooks()))

if wants("agy"):
    add_file("agy profile", profile_dir / "agy.json", agy_profile_source, agy_profile_data)
    for label, target, source in (
        ("agy wrapper", agy_bin / "agy-with-permissions", agy_wrapper_source),
        ("agy lifecycle adapter", agy_bin / "agy-hook-notify.sh", agy_adapter_source),
    ):
        # The existing agy installer remains the single owner of these writes.
        reject_target_kind(target)
        if target.exists():
            try:
                current = target.read_bytes()
            except OSError as exc:
                raise SetupError(f"cannot read existing target: {target}") from exc
            if current != source_data[source]:
                state = "different"
            else:
                state = "unchanged" if mode_bits(target) == source_mode(source) else "mode-different"
        else:
            state = "missing"
        agy_target_states.append((label, target, state))
    registration = load_json(agy_registration_source, "agy hook registration fragment")
    if not isinstance(registration, dict) or set(registration) != {"agy-result-hook"}:
        raise SetupError(f"malformed agy hook registration fragment: {agy_registration_source}")
    expected_registration = copy.deepcopy(registration)
    for handler in expected_registration["agy-result-hook"].get("PostInvocation", []):
        if isinstance(handler, dict) and handler.get("command"):
            handler["command"] = str(agy_bin / "agy-hook-notify.sh")
    reject_target_kind(agy_hooks_config)
    if agy_hooks_config.exists():
        existing_registration_config = load_json(agy_hooks_config, "agy hooks config")
        if not isinstance(existing_registration_config, dict):
            raise SetupError(f"malformed agy hooks config; expected a JSON object: {agy_hooks_config}")
        agy_registration_ready = existing_registration_config.get("agy-result-hook") == expected_registration["agy-result-hook"]
        if not agy_registration_ready:
            agy_delegate_needed = True
    else:
        agy_delegate_needed = True
    if any(state != "unchanged" for _, _, state in agy_target_states):
        agy_delegate_needed = True

if with_pi:
    add_directory("global Pi directory", home / ".pi" / "agent")
    add_directory("global Pi agents directory", home / ".pi" / "agent" / "agents")
    add_directory("global Pi skills directory", home / ".pi" / "agent" / "skills" / "cmux-agent-orchestration")
    agent_text = source_data[pi_agent_source].decode("utf-8")
    needle = "skillPath: ../../skills"
    if agent_text.count(needle) != 1:
        raise SetupError(f"unexpected skillPath in Pi agent source: {pi_agent_source}")
    rewritten_agent = agent_text.replace(needle, "skillPath: ../skills").encode("utf-8")
    add_file("global Pi supervisor agent", home / ".pi" / "agent" / "agents" / "cmux-agent.md", pi_agent_source, rewritten_agent)
    add_file(
        "global Pi orchestration skill",
        home / ".pi" / "agent" / "skills" / "cmux-agent-orchestration" / "SKILL.md",
        pi_skill_source,
    )


def executable_status(name: str) -> tuple[bool, str]:
    found = shutil.which(name)
    return (found is not None, found or "not found")


cursor_agent_ready, cursor_agent_path = executable_status("agent")
agy_cli_ready, agy_cli_path = executable_status("agy")


def print_plan() -> None:
    print(f"Profile selection: {selected} (explicit; no CLI auto-detection)")
    print("Mode: " + ("read-only check" if mode == "check" else "read-only plan" if mode == "plan" else "apply"))
    for directory in directories:
        action = "keep" if directory.state == "present" else "create during --apply"
        print(f"  {action}: {directory.label}: {directory.target}")
    for item in items:
        if item.state == "unchanged":
            action = "skip byte-identical"
        elif item.state == "mode-different":
            action = "repair mode after confirmation"
        elif item.state == "missing":
            action = "create during --apply"
        else:
            action = "replace only after confirmation"
        print(f"  {action}: {item.label}: {item.target}")
    for hook in hook_plans:
        if hook.state == "unchanged":
            action = "skip; required entries already present"
        elif hook.state == "missing":
            action = "create during --apply"
        else:
            action = "merge additively only after confirmation"
        print(f"  {action}: {hook.label}: {hook.target}")
    for label, target, state in agy_target_states:
        action = "delegate; byte-identical target" if state == "unchanged" else "delegate to agy-install.sh"
        print(f"  {action}: {label}: {target}")
    if wants("agy"):
        if agy_registration_ready:
            print(f"  skip; agy hook registration already matches: {agy_hooks_config}")
        else:
            print(f"  delegate additive agy hook registration to agy-install.sh: {agy_hooks_config}")
    if wants("cursor"):
        if advisor_requested:
            print("  optional Cursor advisor requested: install advisor and authoritative command-policy helper")
        else:
            print("  optional Cursor advisor: not selected; no advisor files will be installed")
    if with_pi:
        print("  global Pi installation requested: rewrite only the documented skillPath in the copied agent")
    if wants("cursor"):
        print(f"  preflight Cursor executable: {'ready' if cursor_agent_ready else 'missing'} ({cursor_agent_path})")
    if wants("agy"):
        print(f"  preflight agy executable: {'ready' if agy_cli_ready else 'missing'} ({agy_cli_path})")
    print("No CMUX_AGENT_EXECUTOR or shell startup file will be set or edited.")
    print("No credentials, tokens, command output, or per-job runtime state will be created.")


def atomic_write(path: Path, data: bytes, mode_bits_value: int) -> None:
    reject_target_kind(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    # O_EXCL plus os.replace keeps a partially written file from becoming the
    # destination.  A direct target symlink was rejected before this point.
    fd = -1
    temporary: Path | None = None
    try:
        fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.cmux-agent-setup-", dir=str(path.parent))
        temporary = Path(temporary_name)
        os.fchmod(fd, mode_bits_value)
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
    # Read one line through the raw descriptor.  Python's buffered stdin can
    # otherwise consume confirmations intended for the delegated agy installer.
    print(question, end="", flush=True)
    answer = bytearray()
    while True:
        chunk = os.read(0, 1)
        if not chunk or chunk == b"\n":
            break
        if chunk != b"\r":
            answer.extend(chunk)
    return answer.decode("utf-8", "replace").strip().lower() in {"y", "yes"}


def apply_setup() -> int:
    mutations = [directory for directory in directories if directory.needs_create]
    mutations.extend(item for item in items if item.needs_write)
    mutations.extend(hook for hook in hook_plans if hook.needs_write)
    if agy_delegate_needed:
        mutations.append("agy installer delegation")
    if not mutations:
        print("Already ready; no changes required.")
        return 0
    print_plan()
    if not ask("Apply exactly the changes above? (y/N) "):
        print("Aborted; nothing was changed.")
        return 1

    skipped = False
    try:
        for directory in directories:
            if directory.needs_create:
                reject_directory_kind(directory.target)
                directory.target.mkdir(parents=True, exist_ok=True)
                print(f"Created {directory.label}: {directory.target}")
        for item in items:
            if item.state == "unchanged":
                continue
            if item.state in {"different", "mode-different"} and not ask(f"Replace differing {item.label} at {item.target}? (y/N) "):
                print(f"Skipped differing target: {item.target}")
                skipped = True
                continue
            atomic_write(item.target, item.data, item.mode)
            print(f"Installed {item.label}: {item.target}")
        for hook in hook_plans:
            if not hook.needs_write:
                continue
            if hook.state == "different" and not ask(
                f"Merge additive hook entries into differing {hook.label} at {hook.target}? (y/N) "
            ):
                print(f"Skipped hook config: {hook.target}")
                skipped = True
                continue
            target_mode = mode_bits(hook.target) if hook.target.exists() else 0o644
            atomic_write(hook.target, hook.merged_bytes, target_mode)
            print(f"Updated {hook.label}: {hook.target}")
    except SetupError:
        raise

    if agy_delegate_needed:
        print("Delegating agy wrapper/adapter/hook registration to adapters/agy/agy-install.sh.")
        env = os.environ.copy()
        env["CMUX_AGENT_HOME"] = str(home)
        env["CMUX_AGENT_BIN"] = str(agy_bin)
        env["CMUX_AGENT_HOOKS_CONFIG"] = str(agy_hooks_config)
        result = subprocess.run(["bash", str(agy_installer)], env=env, check=False)
        if result.returncode != 0:
            return result.returncode
    if skipped:
        print("Setup incomplete: one or more differing targets were left unchanged.")
        return 1
    print("Setup applied. Executor selection remains explicit per job or environment; this command did not set CMUX_AGENT_EXECUTOR.")
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
            if item.target.suffix == ".sh" or item.target.name.endswith(".py"):
                if not os.access(item.target, os.X_OK):
                    print(f"  STALE non-executable target: {item.target}")
                    ready = False
                    continue
            print(f"  READY file: {item.target}")
        elif item.state == "missing":
            print(f"  MISSING required file: {item.target}")
            ready = False
        elif item.state == "mode-different":
            print(f"  STALE mode on required file: {item.target}")
            ready = False
        else:
            print(f"  STALE required file: {item.target}")
            ready = False
    for hook in hook_plans:
        if hook.state == "unchanged":
            print(f"  READY hook registration: {hook.target}")
        elif hook.state == "missing":
            print(f"  MISSING hook registration/config: {hook.target}")
            ready = False
        else:
            print(f"  STALE hook registration: {hook.target}")
            ready = False
    for label, target, state in agy_target_states:
        if state == "unchanged" and os.access(target, os.X_OK):
            print(f"  READY agy file: {target}")
        elif state == "unchanged":
            print(f"  STALE non-executable agy file: {target}")
            ready = False
        else:
            print(f"  MISSING or stale agy file ({label}): {target}")
            ready = False
    if wants("agy"):
        if agy_registration_ready:
            print(f"  READY agy hook registration: {agy_hooks_config}")
        else:
            print(f"  MISSING or stale agy hook registration: {agy_hooks_config}")
            ready = False
    if wants("cursor") and not cursor_agent_ready:
        print("  MISSING preflight executable: agent")
        ready = False
    if wants("agy") and not agy_cli_ready:
        print("  MISSING preflight executable: agy")
        ready = False
    if ready:
        print("CHECK READY: selected setup is complete.")
        return 0
    print("CHECK NOT READY: no files or settings were changed.")
    return 1


def main() -> int:
    if mode == "check":
        return check_setup()
    if mode == "apply":
        return apply_setup()
    print_plan()
    return 0


try:
    raise SystemExit(main())
except SetupError as exc:
    print(f"setup: {exc}", file=sys.stderr)
    raise SystemExit(2)
except (OSError, ValueError) as exc:
    print("setup: operation failed safely; no further changes were attempted", file=sys.stderr)
    raise SystemExit(2) from exc
PY
python3 "$python_script" "$repo" "$profile" "$mode" "$advisor" "$with_pi"
