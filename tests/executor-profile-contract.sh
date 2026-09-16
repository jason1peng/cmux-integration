#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
python3 - "$root" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])


def load(path):
    value = json.loads(path.read_text())
    assert isinstance(value, dict), path
    return value


def common(value, expected):
    assert value["profile_id"] == expected
    assert value["schema_version"] == 1
    launch = value["launch"]
    assert isinstance(launch["command"], str) and launch["command"]
    assert isinstance(launch["argv"], list)
    assert all(isinstance(arg, str) for arg in launch["argv"])
    assert launch["mode"] == "headless"
    assert launch["input"] in {"stdin", "prompt-arg"}
    assert isinstance(launch["permission_mode"], str) and launch["permission_mode"]
    for key in ("dangerous", "force", "yolo"):
        assert isinstance(launch[key], bool)
    assert not (launch["force"] or launch["yolo"]) or launch["dangerous"]
    assert value["sandbox"] in {"enabled", "disabled"}
    assert value["network"] in {"enabled", "disabled"}
    assert isinstance(value["write_scope"], list) and value["write_scope"]
    assert all(isinstance(item, str) and item for item in value["write_scope"])
    assert value["cwd"] == {"binding": "contract", "canonicalize": "pwd -P"}
    result = value["result"]
    assert result["completion"] == "process-exit-and-marker"
    assert result["require_marker"] is True
    assert result["format"] in {"text", "jsonl", "stream-json"}
    assert isinstance(result["marker_rule"], str) and "nonce" in result["marker_rule"]
    assert isinstance(result["artifact_checks"], list) and result["artifact_checks"]
    assert isinstance(value["timeout_seconds"], (int, float)) and value["timeout_seconds"] > 0
    assert value["stop"]["mode"] == "process-group"
    assert value["stop"]["deadline_seconds"] > 0

cursor = load(root / "adapters/cursor/executor-profile.cursor.json")
common(cursor, "cursor")
assert cursor["launch"]["command"] == "agent"
assert cursor["launch"]["argv"] == ["--print", "--output-format", "stream-json", "--sandbox", "enabled", "--trust"]
assert cursor["launch"]["input"] == "prompt-arg"
assert cursor["sandbox"] == "enabled"
assert cursor["network"] == "enabled"
assert cursor["write_scope"] == ["cwd"]
assert cursor["launch"]["dangerous"] is False
assert cursor["launch"]["force"] is False
assert cursor["launch"]["yolo"] is False
assert cursor["timeout_seconds"] == 1800
assert "assistant text" in cursor["result"]["marker_rule"]

agy = load(root / "adapters/agy/executor-profile.agy.json")
common(agy, "agy")
assert agy["launch"]["command"] == "agy"
assert agy["launch"]["argv"] == []
assert agy["launch"]["input"] == "stdin"
assert agy["sandbox"] == "enabled"
assert agy["network"] == "enabled"
assert agy["write_scope"] == ["cwd"]
assert agy["launch"]["dangerous"] is False

runner = root / "tools/cmux-agent-run.py"
assert runner.is_file() and runner.stat().st_mode & 0o111
for removed in (
    "cursor-advisor.sh",
    "cursor-hooks.json",
    "cursor-result-watcher.sh",
    "cursor-stop-notify.sh",
    "cursor-transcript-bridge.sh",
):
    assert not (root / "adapters/cursor" / removed).exists(), removed
for removed in (
    "agy-hook-notify.sh",
    "agy-install.sh",
    "agy-result-hook.hooks.json",
    "agy-with-permissions.sh",
):
    assert not (root / "adapters/agy" / removed).exists(), removed

skill = (root / ".agents/skills/cmux-agent/SKILL.md").read_text()
for text in (skill,):
    assert "headless" in text
    assert "cmux-agent" in text
    assert "result.json" in text
    assert "shell=False" in text
    assert "cmux-agent.timeline" not in text
    assert "cursor-transcript-bridge" not in text
    assert "cursor-result-watcher" not in text
    assert "agy-hook-notify" not in text
assert "calling agent" in skill

print("executor profile contract: PASS")
PY
