#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
examples="$root/docs/examples"
profiles_doc="$root/docs/executor-profiles.md"

command -v python3 >/dev/null

python3 - "$examples" <<'PY'
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

examples = Path(sys.argv[1])


def load(name):
    path = examples / name
    with path.open() as stream:
        value = json.load(stream)
    assert isinstance(value, dict), f"{name}: profile must be an object"
    return value


def common(profile, name):
    assert re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", profile["profile_id"]), name
    assert profile["profile_id"] in {"cursor", "agy"}, name
    assert profile["schema_version"] == 1, name
    launch = profile["launch"]
    assert set(launch) == {"command", "argv", "mode", "permission_mode", "dangerous", "force", "yolo"}, name
    assert isinstance(launch["command"], str) and launch["command"], name
    assert isinstance(launch["argv"], list) and all(isinstance(arg, str) for arg in launch["argv"]), name
    assert launch["mode"] in {"interactive", "batch"}, name
    assert isinstance(launch["permission_mode"], str) and launch["permission_mode"], name
    assert isinstance(launch["dangerous"], bool), name
    assert isinstance(launch["force"], bool), name
    assert isinstance(launch["yolo"], bool), name
    assert profile["cwd"] == {"binding": "contract", "canonicalize": "pwd -P"}, name
    probes = profile["probes"]
    assert all(key in probes for key in ("ready", "idle", "question")), name
    transport = profile["transport"]
    for key in ("prompt", "continuation"):
        assert transport[key]["kind"] == "cmux-send", name
        assert transport[key]["requires_workspace"] is True, name
        assert transport[key]["requires_surface"] is True, name
    transcript = profile["transcript"]
    assert transcript["source"], name
    assert transcript["freshness"], name
    result = profile["result"]
    assert "nonce-framed-marker" in result["marker_rule"], name
    assert result["idle_corroboration"] is True, name
    lifecycle = profile["lifecycle"]
    for key in ("event", "source", "required", "acceptable_statuses", "failure_statuses", "correlation", "deduplicate_by"):
        assert key in lifecycle, (name, key)
    assert lifecycle["required"] is True, name
    assert "error" in lifecycle["failure_statuses"], name
    assert "aborted" in lifecycle["failure_statuses"], name
    assert "job_nonce" in lifecycle["correlation"], name
    assert "session_id" in lifecycle["correlation"] or "executor_session" in lifecycle["correlation"], name
    assert profile["stop"]["deadline_seconds"] > 0, name


cursor = load("executor-profile.cursor.json")
common(cursor, "cursor")
assert cursor["profile_id"] == "cursor"
assert cursor["launch"]["command"] == "agent"
assert cursor["launch"]["mode"] == "interactive"
assert cursor["launch"]["argv"] == ["--trust"]
assert cursor["launch"]["permission_mode"] == "explicit-trust"
assert cursor["launch"]["dangerous"] is False
assert cursor["launch"]["force"] is False
assert cursor["launch"]["yolo"] is False
assert cursor["lifecycle"]["event"] == "stop"
assert cursor["lifecycle"]["source"] == "cursor-hooks-stop-adapter"
assert cursor["lifecycle"]["hook_config"] == "${HOME}/.cursor/hooks.json"
assert cursor["lifecycle"]["adapter"] == "${HOME}/.cursor/hooks/cursor-stop-notify.sh"
assert cursor["lifecycle"]["hook_sink"].endswith("cursor-stop.ndjson")
assert "conversation_id" in cursor["lifecycle"]["correlation"]
assert "generation_id" in cursor["lifecycle"]["correlation"]
assert "transcript_path" in cursor["lifecycle"]["correlation"]
assert "prompt echo" in cursor["transcript"]["prompt_echo_rule"]
assert "error" not in cursor["lifecycle"]["acceptable_statuses"]
assert "aborted" not in cursor["lifecycle"]["acceptable_statuses"]

agy = load("executor-profile.agy.json")
common(agy, "agy")
assert agy["profile_id"] == "agy"
assert agy["launch"]["command"] == "${HOME}/bin/agy-with-permissions"
assert agy["launch"]["permission_mode"] == "wrapper-declared-dangerous"
assert agy["launch"]["dangerous"] is True
assert agy["launch"]["force"] is False
assert agy["launch"]["yolo"] is False
assert agy["transcript"]["source"] == "${HOME}/agi-result.txt"
assert agy["transcript"]["hook"] == "agy-result-hook"
assert agy["lifecycle"]["event"] == "PostInvocation"
assert agy["lifecycle"]["hook_registration"] == "PostInvocation"
assert agy["lifecycle"]["hook"].endswith("agy-hook-notify.sh")

hooks = json.loads((examples / "cursor-hooks.json").read_text())
assert hooks["hooks"]["stop"][0]["command"] == ".cursor/hooks/cursor-stop-notify.sh"
assert hooks["hooks"]["stop"][0]["timeout"] == 5

# Exercise the shared evidence boundaries as data-level contract tests. Production
# supervision remains in the skill/supervisor; these checks prevent templates and
# future adapters from weakening the gate.
nonce = "nonce-test-001"
marker = f"<!-- CMX_JOB {nonce} -->\n<!-- GOAL_COMPLETE -->"
prompt = f"Please finish the job.\n{marker}"
fresh_result = f"assistant result\n{marker}\nartifact=ok"
stale_result = fresh_result.replace(nonce, "old-nonce")


def accepts_marker(segment, submitted_prompt, expected_nonce):
    # A result marker is valid only when the nonce and marker are complete,
    # adjacent lines in fresh result data, never in the submitted prompt echo.
    expected = re.compile(
        rf"^<!-- CMX_JOB {re.escape(expected_nonce)} -->$\n^<!-- GOAL_COMPLETE -->$",
        re.MULTILINE,
    )
    return submitted_prompt not in segment and expected.search(segment) is not None


assert accepts_marker(fresh_result, prompt, nonce)
assert not accepts_marker(prompt, prompt, nonce), "prompt echo must not complete"
assert not accepts_marker(stale_result, prompt, nonce), "stale nonce must not complete"
assert not accepts_marker(
    f"reflected prompt only\n{prompt}", prompt, nonce
), "a marker in reflected prompt input must not complete"
assert not accepts_marker(
    f"<!-- CMX_JOB {nonce} --> <!-- GOAL_COMPLETE -->", prompt, nonce
), "markers must remain nonce-framed on separate lines"

active = {
    "job_nonce": nonce,
    "conversation_id": "conversation-test",
    "generation_id": "generation-test",
    "session_id": "session-test",
    "workspace": "workspace-test",
    "surface": "surface-test",
}
seen = set()


def accepts_stop(event):
    if event.get("status") not in {"success", "completed", "ok"}:
        return False
    if event.get("status") in {"error", "aborted"}:
        return False
    if any(event.get(key) != value for key, value in active.items()):
        return False
    identity = (event.get("event_id"), event.get("session_id"), event.get("generation_id"))
    if identity in seen:
        return False
    seen.add(identity)
    return True


stop = {**active, "event_id": "event-test", "status": "completed"}
assert accepts_stop(stop)
assert not accepts_stop(stop), "replayed lifecycle event must be deduplicated"
error_stop = {**stop, "event_id": "event-error", "status": "error"}
assert not accepts_stop(error_stop), "error lifecycle status must fail closed"
stale_stop = {**stop, "event_id": "event-stale", "generation_id": "old-generation"}
assert not accepts_stop(stale_stop), "stale generation must fail closed"

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    target = root / "canonical"
    target.mkdir()
    alias = root / "alias"
    alias.symlink_to(target, target_is_directory=True)
    assert os.path.realpath(alias) == os.path.realpath(target), "cwd must be canonicalized"

    # Exercise the actual shell-text launch boundary with spaces and shell
    # metacharacters in the contract cwd, command path, and argv. Each value
    # must remain one shell word; otherwise command substitution or splitting
    # changes the launch or executes injected text.
    injection_markers = {
        "cwd": root / "cwd-substitution-marker",
        "command": root / "command-substitution-marker",
        "argv": root / "argv-substitution-marker",
    }
    launch_cwd = root / 'contract cwd;$(touch "$CMUX_TEST_CWD_MARKER")'
    launch_cwd.mkdir()
    launch_command = root / 'executor command;$(touch "$CMUX_TEST_COMMAND_MARKER").sh'
    launch_command.write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "{\n"
        "  pwd -P\n"
        "  printf '%s\\n' \"$@\"\n"
        "} > \"$CMUX_TEST_OUTPUT\"\n"
    )
    launch_command.chmod(0o755)
    launch_argv = [
        "argument with spaces",
        'argument;$(touch "$CMUX_TEST_ARGV_MARKER")',
        "",
    ]

    def shell_quote(value):
        result = subprocess.run(
            ["bash", "-c", "printf -- '%q' \"$1\"", "shell-quote-test", value],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.removesuffix("\n")

    quoted_cwd = shell_quote(str(launch_cwd))
    quoted_command = shell_quote(str(launch_command))
    quoted_argv = [shell_quote(value) for value in launch_argv]
    launch_text = f"cd -- {quoted_cwd} && exec {quoted_command}"
    launch_text += " " + " ".join(quoted_argv)
    launch_output = root / "launch output.txt"
    launch_environment = os.environ.copy()
    launch_environment["CMUX_TEST_OUTPUT"] = str(launch_output)
    launch_environment["CMUX_TEST_CWD_MARKER"] = str(injection_markers["cwd"])
    launch_environment["CMUX_TEST_COMMAND_MARKER"] = str(injection_markers["command"])
    launch_environment["CMUX_TEST_ARGV_MARKER"] = str(injection_markers["argv"])
    subprocess.run(
        ["bash", "-c", launch_text],
        check=True,
        env=launch_environment,
        capture_output=True,
        text=True,
    )
    assert launch_output.read_text().splitlines() == [
        os.path.realpath(launch_cwd),
        *launch_argv,
    ], "quoted launch must preserve cwd and argv boundaries"
    assert not any(path.exists() for path in injection_markers.values()), (
        "unquoted launch values must not execute command substitutions"
    )

    profile_dir = root / "profiles"
    profile_dir.mkdir()
    (profile_dir / "cursor.json").write_text(json.dumps(cursor))

    profile_id = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

    def resolve(selector=None, default=None):
        # An explicit selector wins over the environment default; neither may
        # escape the configured profile directory.
        chosen = selector if selector is not None else default
        assert isinstance(chosen, str) and profile_id.fullmatch(chosen)
        path = profile_dir / f"{chosen}.json"
        assert path.is_file()
        value = json.loads(path.read_text())
        assert value["profile_id"] == chosen
        return value

    assert resolve("cursor", "missing")["profile_id"] == "cursor"
    assert resolve(None, "cursor")["profile_id"] == "cursor"
    for unsafe in (None, "", "../cursor", "cursor/other", ".", "-"):
        try:
            resolve(unsafe, None)
        except (AssertionError, json.JSONDecodeError):
            pass
        else:
            raise AssertionError(f"unsafe or missing selector resolved: {unsafe!r}")

    (profile_dir / "malformed.json").write_text("{not-json")
    try:
        resolve("malformed")
    except (AssertionError, json.JSONDecodeError):
        pass
    else:
        raise AssertionError("malformed profile resolved")

    wrong_id = dict(cursor)
    wrong_id["profile_id"] = "other"
    (profile_dir / "wrong-id.json").write_text(json.dumps(wrong_id))
    try:
        resolve("wrong-id")
    except AssertionError:
        pass
    else:
        raise AssertionError("profile identity mismatch resolved")

    # Executability is a pre-launch requirement for a resolved command. Use a
    # disposable absolute command so this test never depends on installed CLIs.
    executable = root / "executor"
    executable.write_text("#!/bin/sh\nexit 0\n")
    executable_profile = dict(cursor)
    executable_profile["launch"] = dict(cursor["launch"])
    executable_profile["launch"]["command"] = str(executable)
    (profile_dir / "executable.json").write_text(json.dumps(executable_profile))
    try:
        assert os.access(executable, os.X_OK)
    except AssertionError:
        pass
    else:
        raise AssertionError("non-executable profile command was accepted")
    executable.chmod(0o755)
    assert os.access(executable, os.X_OK)

    # A source boundary must ignore old bytes and reject replacement/truncation.
    source = root / "result.ndjson"
    old_marker = fresh_result.replace(nonce, "old-nonce")
    source.write_text(old_marker)
    offset = source.stat().st_size
    with source.open("a") as stream:
        stream.write(fresh_result)
    appended = source.read_text()[offset:]
    assert accepts_marker(appended, prompt, nonce)
    source.write_text("replacement")
    assert source.stat().st_size < offset

    try:
        resolve(None, None)
    except AssertionError:
        pass
    else:
        raise AssertionError("missing profile selector must fail closed")

print("executor profile JSON/evidence contract: PASS")
PY

# Exercise the copyable adapter in a disposable runtime only; no user hook/config is touched.
runtime=$(mktemp -d "${TMPDIR:-/tmp}/cmux-agent-profile-test.XXXXXX")
trap 'rm -rf "$runtime"' EXIT
valid='{"hook_event_name":"stop","status":"success","conversation_id":"conversation-test","generation_id":"generation-test","session_id":"session-test","transcript_path":"/tmp/transcript-test"}'
printf '%s\n' "$valid" | CMUX_AGENT_RUNTIME="$runtime" "$examples/cursor-stop-notify.sh"
grep -Fq '"hook_event_name":"stop"' "$runtime/events/cursor-stop.ndjson"
if printf '%s\n' '{"hook_event_name":"beforeSubmitPrompt"}' | CMUX_AGENT_RUNTIME="$runtime" "$examples/cursor-stop-notify.sh" 2>/dev/null; then
  echo 'cursor stop adapter accepted a non-stop event' >&2
  exit 1
fi
if printf '%s\n' '{"hook_event_name":"stop","status":"success"}' | CMUX_AGENT_RUNTIME="$runtime" "$examples/cursor-stop-notify.sh" 2>/dev/null; then
  echo 'cursor stop adapter accepted a malformed event' >&2
  exit 1
fi
[[ "$(wc -l < "$runtime/events/cursor-stop.ndjson")" -eq 1 ]]

grep -Fq -- 'Cursor' "$profiles_doc"
grep -Fq -- 'notifications only' "$profiles_doc"
grep -Fq -- 'fail closed' "$profiles_doc"
grep -Fq -- 'pending' "$profiles_doc"
for launch_safety in \
  'shell-quote the contract cwd as one word' \
  'shell-quote `launch.command` plus every `launch.argv` element individually' \
  "printf -- '%q' \"\$value\"" \
  'unquoted concatenation'; do
  grep -Fq -- "$launch_safety" "$profiles_doc"
done
! grep -Eq '/Users/|/home/' "$examples"/*.json "$examples"/*.sh

echo 'executor profile focused contract: PASS'
