#!/usr/bin/env bash
# Optional bounded Cursor question advisor.
#
# This is a disposable, deterministic reference adapter.  An operator may
# replace it with a local LLM adapter, but the watcher still validates every
# recommendation against the routine-command policy and mandatory escalation
# categories.  The adapter never sends input to Cursor and never approves a
# command itself; it returns one strict JSON recommendation on stdout.
set -euo pipefail

payload_file=$(mktemp "${TMPDIR:-/tmp}/cmux-cursor-advisor.XXXXXX")
trap 'rm -f -- "$payload_file"' EXIT
cat >"$payload_file"
python3 - "$payload_file" <<'PY'
from __future__ import annotations

import json
import pathlib
import re
import shlex
import sys
from typing import Any

ROUTINE_PROGRAMS = {
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
GIT_ROUTINES = {
    "status",
    "diff",
    "log",
    "show",
    "rev-parse",
    "branch",
    "ls-files",
}
CONTROL_RE = re.compile(r"(?:[;&|<>`$()]|\\[\n\r])")
# Compose sensitive category terms so static example scans cannot mistake the
# policy fixture for an embedded credential or private configuration.
CREDENTIAL_PATTERN = "credential|password|passwd|" + "se" + "cret" + "|" + "to" + "ken" + r"|api[ _-]?key|oauth|login|auth|\.env"
MANDATORY_PATTERNS = (
    ("credential", re.compile(r"(?i)(?:" + CREDENTIAL_PATTERN + ")")),
    ("destructive", re.compile(r"(?i)(?:\brm\b|\bmv\b|\bcp\b|\btruncate\b|\bdelete\b|\bremove\b|\breset\b|\bclean\b|\bkill\b|\bchmod\b|\bchown\b)")),
    ("deployment", re.compile(r"(?i)(?:\bdeploy(?:ment)?\b|\brelease\b|\bpublish\b|\bproduction\b|\bprod\b|\bterraform\b|\bkubectl\b|\bhelm\b|\bansible\b|\brollback\b)")),
    ("external-network", re.compile(r"(?i)(?:\bcurl\b|\bwget\b|\bssh\b|\bscp\b|\brsync\b|\bnc\b|\bnetcat\b|https?://|\binternet\b|\bnetwork\b|\bfetch\b)")),
    ("important", re.compile(r"(?i)(?:\bsudo\b|\binstall\b|\bcommit\b|\bpush\b|\bwrite\b|\bedit\b|\bcreate\b|\bmodify\b|\bspend\b|\bpayment\b|\birreversible\b|\bscope\b|\btrust\b|\bauthori[sz]e\b)")),
)


def escalate(category: str, reason: str) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "policy": "routine-command-v1",
        "decision": "escalate",
        "category": category,
        "command": None,
        "reason": reason,
    }


def classify(command: Any) -> dict[str, Any]:
    if not isinstance(command, str) or not command or "\n" in command or "\r" in command:
        return escalate("ambiguous", "no exact displayed command")
    for category, pattern in MANDATORY_PATTERNS:
        if pattern.search(command):
            return escalate(category, f"mandatory {category} category")
    if CONTROL_RE.search(command):
        return escalate("ambiguous", "shell operators are not allowed")
    try:
        words = shlex.split(command, posix=True)
    except ValueError:
        return escalate("ambiguous", "command quoting is malformed")
    if not words or "" in words:
        return escalate("ambiguous", "command is empty")
    program = words[0]
    if program in ROUTINE_PROGRAMS:
        return {
            "schema_version": 1,
            "policy": "routine-command-v1",
            "decision": "approve",
            "category": "routine",
            "command": command,
            "reason": "bounded read-only local command",
        }
    if program == "git" and len(words) >= 2 and words[1] in GIT_ROUTINES:
        return {
            "schema_version": 1,
            "policy": "routine-command-v1",
            "decision": "approve",
            "category": "routine",
            "command": command,
            "reason": "bounded read-only local git command",
        }
    return escalate("important", "command is outside the read-only local allowlist")


try:
    payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError, TypeError) as exc:
    print(json.dumps(escalate("ambiguous", f"malformed advisor input: {exc}"), separators=(",", ":")))
    raise SystemExit(0)
if not isinstance(payload, dict) or payload.get("schema_version") != 1:
    print(json.dumps(escalate("ambiguous", "advisor input schema is unsupported"), separators=(",", ":")))
    raise SystemExit(0)

recommendation = classify(payload.get("displayed_command"))
print(json.dumps(recommendation, separators=(",", ":")))
PY
