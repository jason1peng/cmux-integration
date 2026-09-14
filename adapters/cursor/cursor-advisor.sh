#!/usr/bin/env bash
# Optional bounded Cursor question advisor.
#
# This adapter is a recommendation channel only.  It extracts no policy of its
# own: the supervisor-owned routine-command-v2 validator is the single source
# of truth for exact displayed local read-only commands.  The adapter never
# sends input to Cursor and never executes the displayed command.
set -euo pipefail

payload_file=$(mktemp "${TMPDIR:-/tmp}/cmux-cursor-advisor.XXXXXX")
trap 'rm -f -- "$payload_file"' EXIT
cat >"$payload_file"
python3 - "$payload_file" <<'PY'
from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
from typing import Any

POLICY = "routine-command-v2"
VALID_ESCALATION_CATEGORIES = {"credential", "destructive", "deployment", "external-network", "ambiguous", "important", "advisor-failure"}


def exact_version(value: Any) -> bool:
    return type(value) is int and value == 1


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON object key: {key}")
        result[key] = value
    return result


def response(decision: str, category: str, command: Any, reason: str) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "policy": POLICY,
        "decision": decision,
        "category": category,
        "command": command,
        "reason": reason,
    }


def main() -> int:
    try:
        payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_keys)
    except (OSError, UnicodeError, json.JSONDecodeError, TypeError, ValueError):
        print(json.dumps(response("escalate", "advisor-failure", None, "advisor input is malformed"), separators=(",", ":")))
        return 0
    if not isinstance(payload, dict) or not exact_version(payload.get("schema_version")):
        print(json.dumps(response("escalate", "advisor-failure", None, "advisor input schema is unsupported"), separators=(",", ":")))
        return 0
    command = payload.get("displayed_command")
    cwd = payload.get("cwd")
    scopes = payload.get("scope", payload.get("declared_scope", []))
    configured_policy = os.environ.get("CMUX_AGENT_COMMAND_POLICY", "")
    supplied_policy = payload.get("command_policy")
    if supplied_policy is not None and not isinstance(supplied_policy, str):
        print(json.dumps(response("escalate", "advisor-failure", command, "authoritative command policy path is malformed"), separators=(",", ":")))
        return 0
    if configured_policy and supplied_policy and os.path.realpath(configured_policy) != os.path.realpath(supplied_policy):
        # The supervisor-owned path is authoritative. A payload cannot swap in
        # a different executable to manufacture a routine verdict.
        print(json.dumps(response("escalate", "advisor-failure", command, "authoritative command policy path mismatch"), separators=(",", ":")))
        return 0
    policy_command = configured_policy or supplied_policy or ""
    if not isinstance(command, str) or not command or not isinstance(cwd, str) or not pathlib.Path(cwd).is_absolute() or not pathlib.Path(cwd).is_dir() or os.path.realpath(cwd) != cwd:
        print(json.dumps(response("escalate", "ambiguous", command, "no exact displayed command or canonical cwd"), separators=(",", ":")))
        return 0
    try:
        scopes_valid = isinstance(scopes, list) and bool(scopes) and all(
            isinstance(scope, str)
            and bool(scope)
            and "\n" not in scope
            and "\r" not in scope
            and len(scope.encode("utf-8")) <= 512
            for scope in scopes
        )
    except UnicodeEncodeError:
        scopes_valid = False
    if not scopes_valid:
        print(json.dumps(response("escalate", "advisor-failure", command, "declared scope is missing or malformed"), separators=(",", ":")))
        return 0
    if not isinstance(policy_command, str) or not policy_command or "\n" in policy_command or "\r" in policy_command:
        print(json.dumps(response("escalate", "advisor-failure", command, "authoritative command policy is unavailable"), separators=(",", ":")))
        return 0
    policy_path = pathlib.Path(policy_command)
    if not policy_path.is_absolute() or not policy_path.is_file() or not os.access(policy_path, os.X_OK):
        print(json.dumps(response("escalate", "advisor-failure", command, "authoritative command policy is unavailable"), separators=(",", ":")))
        return 0
    arguments = [sys.executable, policy_command, "validate", "--cwd", cwd]
    for scope in scopes:
        arguments.extend(("--scope", scope))
    arguments.extend(("--command", command))
    try:
        completed = subprocess.run(arguments, check=False, capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        print(json.dumps(response("escalate", "advisor-failure", command, "authoritative command policy failed"), separators=(",", ":")))
        return 0
    raw_verdict = completed.stdout.strip()
    if not raw_verdict or len(raw_verdict.splitlines()) != 1:
        print(json.dumps(response("escalate", "advisor-failure", command, "authoritative command policy returned no or multiple results"), separators=(",", ":")))
        return 0
    try:
        verdict = json.loads(raw_verdict, object_pairs_hook=reject_duplicate_keys)
    except (json.JSONDecodeError, TypeError, ValueError):
        print(json.dumps(response("escalate", "advisor-failure", command, "authoritative command policy returned malformed JSON"), separators=(",", ":")))
        return 0
    if not isinstance(verdict, dict) or not exact_version(verdict.get("schema_version")) or verdict.get("policy") != POLICY:
        print(json.dumps(response("escalate", "advisor-failure", command, "authoritative command policy version is invalid"), separators=(",", ":")))
        return 0
    if verdict.get("command") != command:
        print(json.dumps(response("escalate", "advisor-failure", command, "authoritative command policy returned a command mismatch"), separators=(",", ":")))
        return 0
    if completed.returncode == 0 and verdict.get("decision") == "approve" and verdict.get("category") == "routine":
        print(json.dumps(response("approve", "routine", command, "authoritative v2 validator approved exact command"), separators=(",", ":")))
    else:
        category = verdict.get("category")
        reason = verdict.get("reason")
        try:
            reason_valid = isinstance(category, str) and category in VALID_ESCALATION_CATEGORIES and isinstance(reason, str) and bool(reason) and "\n" not in reason and "\r" not in reason and len(reason.encode("utf-8")) <= 512
        except UnicodeEncodeError:
            reason_valid = False
        if not reason_valid:
            category, reason = "advisor-failure", "authoritative command policy returned malformed output"
        print(json.dumps(response("escalate", category, command, reason), separators=(",", ":")))
    return 0


raise SystemExit(main())
PY
