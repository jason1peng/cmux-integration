#!/usr/bin/env python3
"""CLI-neutral capability/task protocol helpers.

This small, offline tool owns canonical JSON, digest, marker, budget, and
result-envelope rules shared by the Pi supervisor and machine-local adapters.
It never invokes a capability, contacts a server, or executes a command.
"""
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import math
import pathlib
import re
import sys
import time
from typing import Any, Iterable

SCHEMA_VERSION = 1
CAPABILITY_POLICY_VERSION = 1
TASK_CONTRACT_VERSION = 1
MANIFEST_MAX_BYTES = 2048
TASK_CORE_MAX_BYTES = 16 * 1024
REQUEST_RECORD_MAX_BYTES = 8 * 1024
MAX_REQUEST_ATTEMPTS = 3
MAX_OPEN_REQUESTS = 1
MAX_REMINDERS = 1
MAX_DECISION_SECONDS = 60
MAX_FIELD_LENGTH = 512
MAX_ID_LENGTH = 128

AUTHORITY_NONE = "none"
AUTHORITY_LOCAL_READ_ONLY = "local-read-only"
AUTHORITY_VALUES = {AUTHORITY_NONE, AUTHORITY_LOCAL_READ_ONLY}
DISCOVERY_VALUES = {"local", "cached"}
EXECUTION_MODES = {"direct_pi", "supervised_cli_refresh", "manual_handoff"}
EXECUTOR_ROLES = {"assistant", "model", "tool", "function"}
# Transcript adapters may expose pane labels, injected briefs, or supervisor
# continuations using an executor-looking role. Those records are still
# non-authoritative and must not be parsed as readiness/request output.
NON_EXECUTOR_SOURCES = {"brief", "supervisor", "user", "pane", "screen", "label", "system"}
CAPABILITY_KINDS = {"local_skill", "local_read_only_command", "mcp_tool", "network", "external_data"}
DECISIONS = {"approve", "deny", "ask_user"}
SCOPE_CLASSES = {"local-read-only", "local-skill", "mcp", "network", "external-data", "write"}
# Local delegated authority must not be used for credential-bearing or
# externally effective capabilities merely because they are described as
# read-only. Keep this vocabulary conservative and shared by approval and
# recovery checks so both paths fail closed at the same boundary.
LOCAL_SENSITIVE_SCOPE_RE = re.compile(
    r"\b(?:network|mcp|external|write|credential(?:s)?|egress|secret(?:s)?|"
    r"token(?:s)?|passwords?|passwd|api[-_ ]?keys?|private[-_ ]?keys?|"
    r"auth(?:entication|orization)?)\b",
    re.IGNORECASE,
)
RESULT_MARKERS = ("ERROR", "STUCK", "GOAL_COMPLETE", "NEED_APPROVAL", "QUESTION")
RESULT_MARKER_RE = re.compile(
    r"^<!-- (?P<marker>GOAL_COMPLETE) -->$|"
    r"^<!-- (?P<terminal>ERROR|STUCK|NEED_APPROVAL|QUESTION) -->(?: .+)?$"
)
DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
# Capability names are opaque adapter-owned identifiers.  Namespaced forms
# such as ``jira/mr-read`` and ``sourcegraph/search`` are valid, while path
# traversal and empty namespace components remain invalid.
CAPABILITY_ID_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9._:/-]{0,127})$")
MARKER_NONCE_RE = r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}"


def exact_version(value: Any, expected: int) -> bool:
    """Require an integer schema version; JSON 1.0 is not version 1."""
    return isinstance(value, int) and not isinstance(value, bool) and value == expected


def finite_number(value: Any) -> bool:
    """Check finite JSON numbers without leaking OverflowError on huge ints."""
    try:
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    except (OverflowError, TypeError):
        return False
READY_MARKER_RE = re.compile(rf"^<!-- CMX_CAPABILITY_READY (?P<nonce>{MARKER_NONCE_RE}) -->$")
# The strict expression admits authority; the broader expression makes a
# malformed executor-authored readiness attempt fail closed instead of being
# hidden by a second valid record in the same fresh segment.
READY_MARKER_SHAPE_RE = re.compile(r"^[ \t]*<!--[ \t]*CMX_CAPABILITY_READY(?:[ \t]|-->|$).*$")
ANY_REQUEST_MARKER_RE = re.compile(r"^<!-- CMX_CAPABILITY_REQUEST (?P<nonce>[^ ]+) (?P<request_id>[^ ]+) -->$")
# Count malformed marker-shaped lines as attempts too.  The strict expression
# above is used for parsing; this broader expression is deliberately limited
# to a marker on its own transcript line so prose containing the token cannot
# consume the budget.
REQUEST_MARKER_SHAPE_RE = re.compile(r"^[ \t]*<!--\s*CMX_CAPABILITY_REQUEST(?:\s|-->|$).*$")
DECISION_MARKER_RE = re.compile(rf"^<!-- CMX_CAPABILITY_DECISION (?P<nonce>{MARKER_NONCE_RE}) (?P<request_id>{MARKER_NONCE_RE}) -->$")

MANIFEST_KEYS = {
    "capability_policy_version", "delegated_capability_authority", "discovery",
    "initially_authorized", "decision_mode", "limits",
}
DISCOVERY_KEYS = {"local_skill_metadata", "mcp_metadata"}
AUTHORIZED_KEYS = {"skills", "tools", "mcp_servers", "mcp_tools", "network_targets", "write_scope"}
LIMIT_KEYS = {"max_request_attempts", "max_open_requests", "max_reminders", "max_decision_seconds"}
TASK_KEYS = {"task_contract_version", "task_id", "task_text", "target", "context", "scope", "acceptance_criteria", "response_schema"}
REQUEST_KEYS = {
    "schema_version", "job_nonce", "request_id", "kind", "name", "server", "tool",
    "scope", "reason", "expected_effect", "side_effects", "network", "max_duration_seconds",
    # The request cursor is optional on the wire, but when present it binds a
    # grant to the exact fresh transcript position that raised the request.
    "transcript_cursor",
}
REQUEST_REQUIRED_KEYS = {
    "schema_version", "job_nonce", "request_id", "kind", "name", "scope", "reason",
    "expected_effect", "side_effects", "network", "max_duration_seconds",
}
DECISION_KEYS = {
    "schema_version", "job_nonce", "request_id", "executor_identity", "generation",
    "transcript_cursor", "decision", "granted_scope", "expires_at",
}
ROUTE_KEYS = {"execution_mode", "selected_profile", "transport", "lifecycle", "task_payload_sha256"}

# Timeline provenance keys are intentionally not allowed in arbitrary detail
# fields; the protocol uses the same rule when serializing request metadata.
PROVENANCE_KEYS = {
    "schema_version", "event_id", "job_nonce", "source", "event", "at", "at_ms",
    "monotonic_ns", "workspace", "surface", "cwd", "task_payload_sha256",
    "capability_manifest_sha256",
}


class ProtocolError(ValueError):
    """A fail-closed protocol error with a stable machine-readable reason."""

    def __init__(self, code: str, message: str | None = None):
        self.code = code
        super().__init__(message or code)


def fail(code: str, message: str | None = None) -> None:
    raise ProtocolError(code, message)


def _control_free(value: str, *, allow_controls: bool = False) -> None:
    # Canonical manifest/request JSON is single-line and admits no controls.
    # Task text and other task-core strings may preserve ordinary line
    # breaks/tabs for exact identity, but NUL, DEL, and Unicode line
    # separators remain prohibited. Keep the allow-list explicit rather than
    # treating every C0 byte as safe when ``allow_controls`` is enabled.
    allowed = {"\n", "\r", "\t"} if allow_controls else set()
    if any(
        (ord(char) < 0x20 and char not in allowed)
        or ord(char) == 0x7F
        or char in {"\u2028", "\u2029"}
        for char in value
    ):
        fail("control-character", "control/newline characters are not allowed")


def _utf8_size(value: str, code: str) -> int:
    try:
        return len(value.encode("utf-8"))
    except UnicodeEncodeError:
        fail(code, "value is not valid UTF-8")


def _bounded_string(value: Any, name: str, *, max_length: int = MAX_FIELD_LENGTH, allow_controls: bool = False) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{name}-malformed", f"{name} must be a non-empty bounded string")
    size = _utf8_size(value, f"{name}-malformed")
    if size > max_length:
        fail(f"{name}-malformed", f"{name} must be a non-empty bounded string")
    _control_free(value, allow_controls=allow_controls)
    return value


def _bounded_id(value: Any, name: str) -> str:
    value = _bounded_string(value, name, max_length=MAX_ID_LENGTH)
    if not ID_RE.fullmatch(value):
        fail(f"{name}-malformed", f"{name} is not a safe identifier")
    return value


def _bounded_nonce(value: Any, name: str = "job_nonce") -> str:
    value = _bounded_string(value, name, max_length=MAX_ID_LENGTH)
    if not re.fullmatch(MARKER_NONCE_RE, value):
        fail(f"{name}-malformed", f"{name} is not a safe marker nonce")
    return value


def _bounded_capability_id(value: Any, name: str) -> str:
    value = _bounded_string(value, name, max_length=MAX_ID_LENGTH)
    if (
        not CAPABILITY_ID_RE.fullmatch(value)
        or "//" in value
        or any(part in {"", ".", ".."} for part in value.split("/"))
    ):
        fail(f"{name}-malformed", f"{name} is not a safe capability identifier")
    return value


def _json_value(value: Any, *, allow_controls: bool = True) -> None:
    if value is None or isinstance(value, (bool, int, str)):
        if isinstance(value, str):
            _control_free(value, allow_controls=allow_controls)
        return
    if isinstance(value, float):
        if not math.isfinite(value):
            fail("json-nonfinite", "non-finite JSON numbers are not allowed")
        return
    if isinstance(value, list):
        for item in value:
            _json_value(item, allow_controls=allow_controls)
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                fail("json-key-malformed")
            _control_free(key, allow_controls=allow_controls)
            _json_value(item, allow_controls=allow_controls)
        return
    fail("json-value-malformed")


def canonical_bytes(value: Any, *, allow_controls: bool = True) -> bytes:
    _json_value(value, allow_controls=allow_controls)
    try:
        encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    except (TypeError, UnicodeEncodeError, ValueError) as exc:
        fail("json-canonicalization-failed", str(exc))
    return encoded


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """Reject ambiguous JSON objects instead of silently keeping the last key."""
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail("json-duplicate-key", f"duplicate JSON object key: {key}")
        result[key] = value
    return result


def parse_json_value(raw: str, name: str) -> Any:
    if not isinstance(raw, str):
        fail(f"{name}-malformed", f"{name} must be JSON text")
    try:
        value = json.loads(raw, object_pairs_hook=_reject_duplicate_keys)
    except ProtocolError:
        raise
    except (json.JSONDecodeError, TypeError, RecursionError) as exc:
        fail(f"{name}-malformed", str(exc))
    return value


def parse_json_file(path: str, name: str) -> Any:
    try:
        raw = pathlib.Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        fail(f"{name}-unreadable", str(exc))
    return parse_json_value(raw, name)


def _bounded_list(value: Any, name: str, *, item_ids: bool = True) -> list[Any]:
    if not isinstance(value, list) or len(value) > 64:
        fail(f"{name}-malformed", f"{name} must be a bounded list")
    result: list[Any] = []
    for index, item in enumerate(value):
        if item_ids:
            result.append(_bounded_id(item, f"{name}[{index}]"))
        else:
            _json_value(item, allow_controls=False)
            result.append(item)
    return result


def _bounded_string_list(value: Any, name: str) -> list[str]:
    if not isinstance(value, list) or len(value) > 64:
        fail(f"{name}-malformed", f"{name} must be a bounded list")
    return [_bounded_string(item, f"{name}[{index}]") for index, item in enumerate(value)]


def _bounded_capability_list(value: Any, name: str) -> list[str]:
    if not isinstance(value, list) or len(value) > 64:
        fail(f"{name}-malformed", f"{name} must be a bounded list")
    return [_bounded_capability_id(item, f"{name}[{index}]") for index, item in enumerate(value)]


def validate_discovery(value: Any) -> dict[str, str]:
    """Validate the local/cached discovery boundary without contacting MCP."""
    if not isinstance(value, dict) or set(value) != DISCOVERY_KEYS:
        fail("capability-discovery-malformed")
    normalized: dict[str, str] = {}
    for key in sorted(DISCOVERY_KEYS):
        item = value.get(key)
        if not isinstance(item, str) or item not in DISCOVERY_VALUES:
            fail("capability-discovery-value-invalid")
        normalized[key] = item
    return normalized


def validate_manifest(value: Any) -> tuple[dict[str, Any], bytes, str]:
    """Validate and canonicalize one capability manifest."""
    if isinstance(value, str):
        value = parse_json_value(value, "capability-manifest")
    if not isinstance(value, dict):
        fail("capability-manifest-malformed")
    # Version skew is reported before shape errors so absent, malformed, and
    # unknown policy versions all fail closed with the named adapter reason.
    version = value.get("capability_policy_version")
    if not exact_version(version, CAPABILITY_POLICY_VERSION):
        fail("capability-protocol-version-skew")
    authority = value.get("delegated_capability_authority")
    if not isinstance(authority, str) or authority not in AUTHORITY_VALUES:
        # An absent/malformed authority never grants authority.  It is still a
        # malformed manifest so a supervisor cannot mistake it for delegation.
        # Check this before the general shape so the caller receives the
        # authority-specific fail-closed reason even when the field is absent.
        fail("delegated-capability-authority-invalid")
    if set(value) != MANIFEST_KEYS:
        fail("capability-manifest-fields", "manifest fields do not match the versioned contract")
    discovery = validate_discovery(value.get("discovery"))
    authorized = value.get("initially_authorized")
    if not isinstance(authorized, dict) or set(authorized) != AUTHORIZED_KEYS:
        fail("capability-authorized-fields")
    normalized_authorized: dict[str, Any] = {}
    identifier_keys = {"skills", "tools", "mcp_servers", "mcp_tools"}
    for key in ("skills", "tools", "mcp_servers", "mcp_tools", "network_targets", "write_scope"):
        if key in identifier_keys:
            normalized_authorized[key] = _bounded_capability_list(authorized[key], f"initially_authorized.{key}")
        else:
            # Targets/scopes are exact bounded strings, not identifiers: a
            # network target or path may legitimately contain URI/path syntax.
            normalized_authorized[key] = _bounded_string_list(authorized[key], f"initially_authorized.{key}")
    limits = value.get("limits")
    if not isinstance(limits, dict) or set(limits) != LIMIT_KEYS:
        fail("capability-limits-malformed")
    normalized_limits: dict[str, int] = {}
    maxima = {
        "max_request_attempts": MAX_REQUEST_ATTEMPTS,
        "max_open_requests": MAX_OPEN_REQUESTS,
        "max_reminders": MAX_REMINDERS,
        "max_decision_seconds": MAX_DECISION_SECONDS,
    }
    for key, maximum in maxima.items():
        number = limits[key]
        if isinstance(number, bool) or not isinstance(number, int) or number < 0 or number > maximum:
            fail(f"{key}-out-of-bounds")
        normalized_limits[key] = number
    decision_mode = value.get("decision_mode")
    if not isinstance(decision_mode, str) or decision_mode not in {"supervisor", "parent-user", "supervisor-or-parent-user"}:
        fail("capability-decision-mode-invalid")
    normalized = {
        "capability_policy_version": CAPABILITY_POLICY_VERSION,
        "delegated_capability_authority": authority,
        "decision_mode": decision_mode,
        "discovery": {key: discovery[key] for key in sorted(DISCOVERY_KEYS)},
        "initially_authorized": normalized_authorized,
        "limits": normalized_limits,
    }
    encoded = canonical_bytes(normalized, allow_controls=False)
    if b"\n" in encoded or b"\r" in encoded or any(byte < 0x20 or byte == 0x7F for byte in encoded):
        fail("capability-manifest-control-character")
    if len(encoded) > MANIFEST_MAX_BYTES:
        fail("capability-manifest-too-large")
    return normalized, encoded, hashlib.sha256(encoded).hexdigest()


def _bounded_task_core_string(value: Any, name: str, *, allow_controls: bool = False) -> str:
    """Validate a task-core string while preserving the aggregate-size error."""
    if not isinstance(value, str) or not value:
        fail(f"{name}-malformed", f"{name} must be a non-empty bounded string")
    size = _utf8_size(value, f"{name}-malformed")
    if size > TASK_CORE_MAX_BYTES:
        # The task-core wire limit owns oversize handling; do not leak a
        # smaller per-field error or truncate exact user-approved text.
        fail("task-core-too-large")
    _control_free(value, allow_controls=allow_controls)
    return value


def validate_task_core(value: Any) -> tuple[dict[str, Any], bytes, str]:
    """Validate one canonical task core and compute its exact-byte digest."""
    if isinstance(value, str):
        value = parse_json_value(value, "task-core")
    if not isinstance(value, dict):
        fail("task-core-malformed")
    # Missing/unknown versions must not be hidden behind a generic required
    # field error: adapters use this stable reason to refuse route execution
    # and manual-result import before consuming the task.
    version = value.get("task_contract_version")
    if not exact_version(version, TASK_CONTRACT_VERSION):
        fail("task-contract-version-skew")
    extra_keys = set(value) - TASK_KEYS
    if extra_keys and extra_keys != {"execution_mode"}:
        fail("task-core-fields")
    if not TASK_KEYS.issubset(value):
        fail("task-core-fields")
    # The aggregate 16 KiB bound is the wire limit. Keep task IDs bounded as
    # identifiers, but do not impose the request-field 512-byte limit on
    # target/scope/acceptance text; their exact bytes still participate in the
    # aggregate check below.
    _bounded_string(value["task_id"], "task_id", max_length=MAX_ID_LENGTH)
    for key in ("target", "scope", "acceptance_criteria"):
        _bounded_task_core_string(value[key], key)
    # Task text is exact user-approved content and may contain ordinary line
    # breaks; JSON canonicalization escapes them without truncating them. Keep
    # the aggregate task-core bound as the owner of oversize handling.
    _bounded_task_core_string(value["task_text"], "task_text", allow_controls=True)
    context = value["context"]
    response_schema = value["response_schema"]
    _json_value(context, allow_controls=True)
    _json_value(response_schema, allow_controls=True)
    # Route metadata must never become part of the task identity.
    def contains_route_key(item: Any) -> bool:
        if isinstance(item, dict):
            return any(key == "execution_mode" or contains_route_key(child) for key, child in item.items())
        if isinstance(item, list):
            return any(contains_route_key(child) for child in item)
        return False
    if contains_route_key(value):
        fail("task-core-route-metadata")
    normalized = {key: value[key] for key in sorted(TASK_KEYS)}
    encoded = canonical_bytes(normalized, allow_controls=True)
    if len(encoded) > TASK_CORE_MAX_BYTES:
        fail("task-core-too-large")
    return normalized, encoded, hashlib.sha256(encoded).hexdigest()


def route_envelope(
    execution_mode: str | None = None,
    *,
    selected_profile: str | None = None,
    transport: Any = None,
    lifecycle: Any = None,
    task_payload_sha256: str | None = None,
) -> dict[str, Any]:
    # Omitting route selection preserves the existing direct Pi path. Unknown
    # non-empty values still fail closed rather than falling back silently.
    if execution_mode is None:
        # Only an omitted route selects the direct Pi path. An explicitly
        # empty value is malformed input and must not silently bypass profile
        # selection or route validation.
        execution_mode = "direct_pi"
    if not isinstance(execution_mode, str) or execution_mode not in EXECUTION_MODES:
        fail("execution-mode-invalid")
    if execution_mode == "direct_pi" and any(value is not None for value in (selected_profile, transport, lifecycle)):
        fail("direct-route-metadata")
    if execution_mode == "supervised_cli_refresh" and selected_profile is None:
        fail("supervised-route-profile-missing")
    envelope: dict[str, Any] = {"execution_mode": execution_mode}
    # direct_pi deliberately has no profile, transport, or lifecycle route;
    # optional adapters cannot silently replace the current Pi conversation.
    if execution_mode != "direct_pi" and selected_profile is not None:
        envelope["selected_profile"] = _bounded_id(selected_profile, "selected_profile")
    if execution_mode != "direct_pi" and transport is not None:
        _json_value(transport, allow_controls=False)
        envelope["transport"] = transport
    if execution_mode != "direct_pi" and lifecycle is not None:
        _json_value(lifecycle, allow_controls=False)
        envelope["lifecycle"] = lifecycle
    if task_payload_sha256 is not None:
        if not isinstance(task_payload_sha256, str) or not DIGEST_RE.fullmatch(task_payload_sha256):
            fail("task-payload-hash-malformed")
        envelope["task_payload_sha256"] = task_payload_sha256
    return envelope


def digest_record(manifest: Any, task_core: Any) -> dict[str, Any]:
    _, manifest_bytes, manifest_digest = validate_manifest(manifest)
    _, task_bytes, task_digest = validate_task_core(task_core)
    return {
        "capability_manifest": manifest_bytes.decode("utf-8"),
        "capability_manifest_sha256": manifest_digest,
        "task_core": task_bytes.decode("utf-8"),
        "task_payload_sha256": task_digest,
    }


def _line_records(segment: str | bytes | Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    if isinstance(segment, bytes):
        try:
            segment = segment.decode("utf-8")
        except UnicodeDecodeError:
            fail("transcript-utf8-invalid")
    if isinstance(segment, str):
        records: list[dict[str, Any]] = []
        for raw in segment.splitlines():
            if not raw.strip():
                continue
            value = parse_json_value(raw, "transcript-record")
            if not isinstance(value, dict):
                fail("transcript-record-malformed")
            records.append(value)
        return records
    records = list(segment)
    if any(not isinstance(record, dict) for record in records):
        fail("transcript-record-malformed")
    return records


def _record_identity_value(record: dict[str, Any], *keys: str) -> Any:
    """Read only documented identity containers, never arbitrary content."""
    for key in keys:
        if key in record:
            return record[key]
    for container_name in ("metadata", "context", "identity", "identities", "routing"):
        container = record.get(container_name)
        if isinstance(container, dict):
            for key in keys:
                if key in container:
                    return container[key]
    return None


def record_role(record: dict[str, Any]) -> str:
    role = _record_identity_value(record, "role", "author", "speaker")
    if not isinstance(role, str):
        return ""
    return role.strip().casefold()


def executor_record(record: dict[str, Any]) -> bool:
    """Return whether a transcript record can author protocol markers."""
    if record_role(record) not in EXECUTOR_ROLES:
        return False
    source = _record_identity_value(record, "source", "record_source", "origin")
    return not (isinstance(source, str) and source.strip().casefold() in NON_EXECUTOR_SOURCES)


def _stringify_content(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float, bool)):
        return str(value)
    if isinstance(value, list):
        return "\n".join(part for part in (_stringify_content(item) for item in value) if part)
    if isinstance(value, dict):
        for key in ("text", "content", "value", "output"):
            if key in value:
                rendered = _stringify_content(value[key])
                if rendered:
                    return rendered
    return ""


def record_content(record: dict[str, Any]) -> str:
    for key in ("content", "text", "output", "message", "tool_result", "tool_call"):
        if key in record:
            value = _stringify_content(record[key])
            if value:
                return value
    return ""


def _exact_echo(record: dict[str, Any], content: str, injected_lines: set[str]) -> bool:
    if record.get("injected") is True or record.get("source") in {"brief", "supervisor", "user"}:
        return True
    return content in injected_lines


def _filtered_content(record: dict[str, Any], content: str, injected_lines: set[str]) -> str:
    """Remove only exact injected lines, preserving nearby authored output."""
    if _exact_echo(record, content, injected_lines):
        return ""
    if not injected_lines:
        return content
    return "\n".join(line for line in content.splitlines() if line not in injected_lines)


def marker_precedence(content: str) -> str | None:
    """Choose the conservative result marker from one fresh turn.

    Capability requests are approval-tier evidence, but a terminal error/stuck
    or completion marker remains authoritative when both are present.  This
    function only considers marker-shaped output lines; prose mentioning a
    marker name cannot change the route.
    """
    if not isinstance(content, str):
        fail("marker-content-malformed")
    found: set[str] = set()
    for line in content.splitlines():
        match = RESULT_MARKER_RE.fullmatch(line)
        if match:
            found.add(match.group("marker") or match.group("terminal"))
    if "ERROR" in found:
        return "ERROR"
    if "STUCK" in found:
        return "STUCK"
    capability_request = any(REQUEST_MARKER_SHAPE_RE.fullmatch(line) for line in content.splitlines())
    # A capability request is NEED_APPROVAL-tier evidence, but the ordinary
    # NEED_APPROVAL marker remains the more conservative result when it
    # coexists with a completion marker.  Only a GOAL_COMPLETE paired with a
    # capability request is allowed to retain completion precedence, as the
    # request may have been emitted after the work was already complete.
    if "GOAL_COMPLETE" in found and capability_request:
        return "GOAL_COMPLETE"
    if "NEED_APPROVAL" in found:
        return "NEED_APPROVAL"
    if "QUESTION" in found:
        return "QUESTION"
    if "GOAL_COMPLETE" in found:
        return "GOAL_COMPLETE"
    if capability_request:
        return "NEED_APPROVAL"
    return None


def _fresh_correlated(record: dict[str, Any]) -> bool:
    """Honor explicit freshness/correlation latches from profile adapters."""
    for key in ("fresh", "correlated"):
        if key in record and record.get(key) is not True:
            return False
    for key in ("stale", "replayed"):
        if record.get(key) is True:
            return False
    return True


def _identity_matches(record: dict[str, Any], *, job_nonce: str, executor_identity: str | None, generation: str | None) -> bool:
    # Capability authority requires both active bindings.  Callers may omit
    # them when inspecting ordinary transcript text, but a marker can never
    # become authority without an executor identity and generation.
    if not isinstance(executor_identity, str) or not executor_identity or not isinstance(generation, str) or not generation:
        return False
    record_nonce = _record_identity_value(record, "job_nonce", "jobNonce")
    if record_nonce not in (None, job_nonce):
        return False
    if executor_identity is not None:
        identity_fields = ("executor_identity", "executor_session", "session_id")
        # A caller-provided active identity is meaningful only when the fresh
        # record carries one of the identity fields.  Accepting a record with
        # no binding would turn an uncorrelated transcript into authority.
        present = False
        for key in identity_fields:
            value = _record_identity_value(record, key)
            if value is not None:
                present = True
                if value != executor_identity:
                    return False
        if not present:
            return False
    if generation is not None:
        generation_fields = ("generation", "generation_id")
        present = False
        for key in generation_fields:
            value = _record_identity_value(record, key)
            if value is not None:
                present = True
                if value != generation:
                    return False
        if not present:
            return False
    return True


def _canonical_line_object(raw: str, name: str) -> dict[str, Any]:
    if not isinstance(raw, str):
        fail(f"{name}-malformed")
    if "\n" in raw or "\r" in raw or _utf8_size(raw, f"{name}-utf8-invalid") > REQUEST_RECORD_MAX_BYTES:
        fail(f"{name}-record-too-large")
    value = parse_json_value(raw, name)
    if not isinstance(value, dict):
        fail(f"{name}-not-object")
    try:
        canonical = canonical_bytes(value, allow_controls=False).decode("utf-8")
    except ProtocolError:
        raise
    if canonical != raw:
        fail(f"{name}-not-canonical")
    return value


def validate_ready_payload(raw: str, *, manifest_digest: str, task_digest: str) -> dict[str, Any]:
    value = _canonical_line_object(raw, "capability-ready")
    ready_version = value.get("schema_version")
    if not exact_version(ready_version, SCHEMA_VERSION):
        fail("capability-ready-schema-version-skew")
    if set(value) != {"schema_version", "manifest_sha256", "task_payload_sha256"}:
        fail("capability-ready-malformed")
    if not isinstance(value.get("manifest_sha256"), str) or not DIGEST_RE.fullmatch(value["manifest_sha256"]):
        fail("capability-ready-digest-malformed")
    if not isinstance(value.get("task_payload_sha256"), str) or not DIGEST_RE.fullmatch(value["task_payload_sha256"]):
        fail("capability-ready-digest-malformed")
    if value["manifest_sha256"] != manifest_digest or value["task_payload_sha256"] != task_digest:
        fail("capability-ready-digest-mismatch")
    return value


def parse_readiness(segment: str | bytes | Iterable[dict[str, Any]], *, job_nonce: str, manifest: Any, task_core: Any, executor_identity: str | None = None, generation: str | None = None, injected_lines: Iterable[str] = ()) -> dict[str, Any]:
    _bounded_nonce(job_nonce)
    if executor_identity is not None:
        _bounded_id(executor_identity, "executor_identity")
    if generation is not None:
        _bounded_id(generation, "generation")
    _, _, manifest_digest = validate_manifest(manifest)
    _, _, task_digest = validate_task_core(task_core)
    records = _line_records(segment)
    injected = set(injected_lines)
    found: list[dict[str, Any]] = []
    malformed = False
    for record in records:
        if not executor_record(record):
            continue
        content = _filtered_content(record, record_content(record), injected)
        if not content:
            continue
        lines = content.splitlines()
        for index, line in enumerate(lines):
            shape = READY_MARKER_SHAPE_RE.fullmatch(line)
            if not shape:
                continue
            match = READY_MARKER_RE.fullmatch(line)
            if not match:
                malformed = True
                continue
            if (
                match.group("nonce") != job_nonce
                or not _fresh_correlated(record)
                or not _identity_matches(record, job_nonce=job_nonce, executor_identity=executor_identity, generation=generation)
            ):
                malformed = True
                continue
            # Readiness is an exact pair. Any prefix/suffix text would make
            # it unclear whether the digest belongs to this fresh boundary.
            if index != 0 or index + 1 >= len(lines) or len(lines) != 2:
                malformed = True
                continue
            try:
                payload = validate_ready_payload(lines[index + 1], manifest_digest=manifest_digest, task_digest=task_digest)
            except ProtocolError:
                malformed = True
                continue
            found.append({"record": record, "payload": payload})
    if len(found) > 1:
        fail("capability-ready-duplicate")
    if malformed:
        fail("capability-ready-mismatch")
    if not found:
        fail("capability-ready-missing")
    return found[0]


def validate_request(value: Any, *, job_nonce: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail("capability-request-fields")
    _bounded_nonce(job_nonce)
    request_version = value.get("schema_version")
    if not exact_version(request_version, SCHEMA_VERSION):
        fail("capability-request-schema-version-skew")
    if set(value) - REQUEST_KEYS:
        fail("capability-request-fields")
    if not REQUEST_REQUIRED_KEYS.issubset(value):
        fail("capability-request-fields", "required capability request field is missing")
    if value.get("job_nonce") != job_nonce:
        fail("capability-request-stale")
    normalized = dict(value)
    _bounded_id(value.get("request_id"), "request_id")
    kind = value.get("kind")
    if not isinstance(kind, str) or kind not in CAPABILITY_KINDS:
        fail("capability-request-kind-invalid")
    # Skill/tool names are identifiers. Network and external-data requests use
    # an exact bounded target instead (for example https://host/path); forcing
    # those values through the identifier grammar would make an egress request
    # impossible to represent and encourage an unsafe shorthand.
    if kind in {"network", "external_data"}:
        _bounded_string(value.get("name"), "name")
    else:
        _bounded_capability_id(value.get("name"), "name")
    if kind == "mcp_tool":
        _bounded_id(value.get("server"), "server")
        _bounded_id(value.get("tool"), "tool")
    else:
        if "server" in value or "tool" in value:
            fail("capability-request-mcp-fields-invalid")
    for key in ("scope", "reason", "expected_effect", "side_effects"):
        _bounded_string(value.get(key), key)
    if not isinstance(value.get("network"), bool):
        fail("capability-request-network-invalid")
    if "transcript_cursor" in value:
        cursor = value["transcript_cursor"]
        if isinstance(cursor, bool) or not isinstance(cursor, int) or cursor < 0 or cursor > 2**63 - 1:
            fail("capability-request-cursor-invalid")
    seconds = value.get("max_duration_seconds")
    if not finite_number(seconds) or seconds < 0 or seconds > MAX_DECISION_SECONDS:
        fail("capability-request-duration-invalid")
    # Ensure the exact request bytes are bounded and single-line canonical JSON.
    encoded = canonical_bytes(normalized, allow_controls=False)
    if len(encoded) > REQUEST_RECORD_MAX_BYTES:
        fail("capability-request-record-too-large")
    return normalized


def request_from_content(content: str, *, job_nonce: str) -> tuple[list[dict[str, Any]], list[str]]:
    """Parse marker+JSON pairs from one executor turn.

    All marker-shaped attempts are returned as an attempt list, including stale
    and malformed forms; callers must count every one against the budget.
    """
    if not isinstance(content, str):
        fail("capability-request-content-malformed")
    lines = content.splitlines()
    requests: list[dict[str, Any]] = []
    errors: list[str] = []
    index = 0
    while index < len(lines):
        marker = ANY_REQUEST_MARKER_RE.fullmatch(lines[index])
        if not marker:
            if REQUEST_MARKER_SHAPE_RE.fullmatch(lines[index]):
                errors.append("capability-request-marker-malformed")
                # The malformed marker itself is the attempt.  Do not consume
                # the following line: it may contain a second marker and must
                # be counted independently.
            index += 1
            continue
        nonce = marker.group("nonce")
        request_id = marker.group("request_id")
        if nonce != job_nonce:
            errors.append("capability-request-stale")
            index += 1
            continue
        if index + 1 >= len(lines):
            errors.append("capability-request-record-missing")
            index += 1
            continue
        # A marker immediately following another marker is itself an attempt;
        # do not consume it as the first marker's JSON payload.  This keeps
        # malformed/multiple-in-one-turn attempts visible to the budget.
        if REQUEST_MARKER_SHAPE_RE.fullmatch(lines[index + 1]):
            errors.append("capability-request-record-malformed")
            index += 1
            continue
        try:
            marker_size = len(lines[index].encode("utf-8"))
            next_line_size = len(lines[index + 1].encode("utf-8"))
        except UnicodeEncodeError:
            errors.append("capability-request-utf8-invalid")
            index += 1
            continue
        # The bounded record is the marker plus its immediately following
        # canonical JSON line, including their separator.  A large JSON line
        # must never be admitted merely because the marker was omitted from
        # the size calculation.
        if marker_size + 1 + next_line_size > REQUEST_RECORD_MAX_BYTES:
            errors.append("capability-request-record-too-large")
            index += 1
            continue
        try:
            request = validate_request(_canonical_line_object(lines[index + 1], "capability-request"), job_nonce=job_nonce)
            if request.get("request_id") != request_id:
                fail("capability-request-identity-mismatch")
            # A request record is exactly one marker/object pair. Any
            # non-empty trailing line is ambiguous (another JSON value,
            # prose, or a marker) and must not be silently ignored.
            if index + 2 < len(lines) and any(line.strip() for line in lines[index + 2:]):
                fail("capability-request-multiple-records")
            requests.append(request)
        except ProtocolError as exc:
            errors.append(exc.code)
        index += 2
    return requests, errors


@dataclasses.dataclass
class CapabilityBudget:
    request_attempts: int = 0
    open_request: str | None = None
    reminders: int = 0
    grants: list[dict[str, Any]] = dataclasses.field(default_factory=list)
    decisions: list[dict[str, Any]] = dataclasses.field(default_factory=list)
    # Persist every valid request identity that reached the decision boundary.
    # An open request alone is insufficient replay protection: a repeated
    # marker with the same request ID must remain rejected even before a
    # decision is recorded.
    seen_request_ids: list[str] = dataclasses.field(default_factory=list)
    pending_user_request: str | None = None
    # Effective limits are persisted with the job state.  They may be lower
    # than the protocol maxima, but never higher.
    max_request_attempts: int = MAX_REQUEST_ATTEMPTS
    max_open_requests: int = MAX_OPEN_REQUESTS
    max_reminders: int = MAX_REMINDERS
    max_decision_seconds: int = MAX_DECISION_SECONDS

    def __post_init__(self) -> None:
        maxima = {
            "max_request_attempts": MAX_REQUEST_ATTEMPTS,
            "max_open_requests": MAX_OPEN_REQUESTS,
            "max_reminders": MAX_REMINDERS,
            "max_decision_seconds": MAX_DECISION_SECONDS,
        }
        for key, maximum in maxima.items():
            number = getattr(self, key)
            if isinstance(number, bool) or not isinstance(number, int) or number < 0 or number > maximum:
                fail(f"{key}-out-of-bounds")
        for key in ("request_attempts", "reminders"):
            number = getattr(self, key)
            if isinstance(number, bool) or not isinstance(number, int) or number < 0:
                fail("capability-budget-state-malformed")

    @classmethod
    def from_limits(cls, limits: dict[str, Any] | None) -> "CapabilityBudget":
        if limits is None:
            return cls()
        if not isinstance(limits, dict) or set(limits) - LIMIT_KEYS:
            fail("capability-limits-malformed")
        values: dict[str, int] = {}
        maxima = {
            "max_request_attempts": MAX_REQUEST_ATTEMPTS,
            "max_open_requests": MAX_OPEN_REQUESTS,
            "max_reminders": MAX_REMINDERS,
            "max_decision_seconds": MAX_DECISION_SECONDS,
        }
        for key, maximum in maxima.items():
            number = limits.get(key, maximum)
            if isinstance(number, bool) or not isinstance(number, int) or number < 0 or number > maximum:
                fail(f"{key}-out-of-bounds")
            values[key] = number
        return cls(**values)

    def consume_attempt(self) -> str:
        self.request_attempts += 1
        if self.request_attempts > self.max_request_attempts:
            return "capability-request-budget-exhausted"
        return "accepted"

    def open(self, request_id: str) -> str:
        if self.max_open_requests < 1 or self.open_request is not None:
            return "capability-request-open"
        self.open_request = request_id
        return "accepted"

    def remember_request(self, request_id: str) -> bool:
        """Record a request identity and return whether it was already seen."""
        if request_id in self.seen_request_ids:
            return True
        self.seen_request_ids.append(request_id)
        return False

    def close(self) -> None:
        self.open_request = None

    def issue_reminder(self) -> str:
        if self.reminders >= self.max_reminders:
            return "capability-reminder-budget-exhausted"
        self.reminders += 1
        return "accepted"

    def add_grant(self, decision: dict[str, Any]) -> str:
        """Persist a single-use grant after the supervisor sends its envelope."""
        if not isinstance(decision, dict):
            return "capability-decision-invalid"
        request_id = decision.get("request_id")
        if not isinstance(request_id, str) or not request_id or decision.get("decision") != "approve":
            return "capability-decision-invalid"
        if any(item.get("request_id") == request_id for item in self.grants):
            return "capability-request-replayed"
        existing = next((item for item in self.decisions if item.get("request_id") == request_id), None)
        if existing is not None and not (existing.get("decision") == "ask_user" and self.pending_user_request == request_id):
            return "capability-request-replayed"
        if existing is not None and self.open_request not in (None, request_id):
            return "capability-request-open"
        self.grants.append({**decision, "used": False})
        if existing is None:
            self.decisions.append({"request_id": request_id, "decision": "approve"})
        else:
            existing["decision"] = "approve"
        self.pending_user_request = None
        self.close()
        return "accepted"

    def record_decision(self, request_id: str, decision: str) -> str:
        """Remember a supervisor decision and keep ask-user requests open."""
        if not isinstance(request_id, str) or not request_id or not isinstance(decision, str) or decision not in DECISIONS:
            return "capability-decision-invalid"
        if decision == "approve":
            return "capability-approval-requires-grant"
        existing = next((item for item in self.decisions if item.get("request_id") == request_id), None)
        if existing is not None:
            if existing.get("decision") != "ask_user" or self.pending_user_request != request_id or decision == "ask_user":
                return "capability-request-replayed"
            if self.open_request not in (None, request_id):
                return "capability-request-open"
            existing["decision"] = decision
            self.pending_user_request = None
            self.close()
            return "accepted"
        # A decision for a different request must not close or otherwise alter
        # the currently open request.  This is especially important for a
        # deny path: a stale/foreign denial is still a protocol error, not a
        # way to release an unrelated ask-user checkpoint.
        if self.open_request not in (None, request_id):
            return "capability-request-open"
        self.decisions.append({"request_id": request_id, "decision": decision})
        if decision == "ask_user":
            if self.open_request not in (None, request_id) or self.pending_user_request is not None:
                self.decisions.pop()
                return "capability-request-open"
            self.open_request = request_id
            self.pending_user_request = request_id
        else:
            self.close()
        return "accepted"

    def expire_ask_user(self, request_id: str) -> str:
        """Convert an unanswered ask-user decision to deny at expiry."""
        if self.pending_user_request != request_id:
            return "capability-decision-not-pending"
        existing = next((item for item in self.decisions if item.get("request_id") == request_id), None)
        if existing is None or existing.get("decision") != "ask_user":
            return "capability-decision-not-pending"
        existing["decision"] = "deny"
        self.pending_user_request = None
        self.close()
        return "denied-expired"

    def consume_grant(
        self,
        *,
        job_nonce: str,
        request_id: str,
        executor_identity: str,
        generation: str,
        transcript_cursor: int,
        now: float,
    ) -> tuple[str, dict[str, Any] | None]:
        """Consume a grant only once and only at its original binding."""
        for grant in self.grants:
            if grant.get("request_id") != request_id:
                continue
            if grant.get("job_nonce") != job_nonce or grant.get("executor_identity") != executor_identity or grant.get("generation") != generation or grant.get("transcript_cursor") != transcript_cursor:
                return "capability-grant-binding-mismatch", None
            if grant.get("used") is True:
                return "capability-grant-replayed", None
            if grant.get("used") is not False:
                return "capability-grant-invalid", None
            expiry = grant.get("expires_at")
            try:
                valid_clock = (
                    isinstance(now, (int, float))
                    and not isinstance(now, bool)
                    and math.isfinite(now)
                    and isinstance(expiry, (int, float))
                    and not isinstance(expiry, bool)
                    and math.isfinite(expiry)
                )
            except (OverflowError, TypeError):
                valid_clock = False
            if not valid_clock:
                return "capability-grant-invalid", None
            if now >= expiry:
                return "capability-grant-expired", None
            grant["used"] = True
            return "accepted", dict(grant)
        return "capability-grant-missing", None

    def as_json(self) -> dict[str, Any]:
        return dataclasses.asdict(self)


def _turn_id(record: dict[str, Any], index: int) -> str:
    value = record.get("turn_id", record.get("generation_id", record.get("generation")))
    return str(value) if value is not None else f"record-{index}"


def parse_requests(segment: str | bytes | Iterable[dict[str, Any]], *, job_nonce: str, executor_identity: str | None = None, generation: str | None = None, injected_lines: Iterable[str] = (), budget: CapabilityBudget | None = None, limits: dict[str, Any] | None = None) -> dict[str, Any]:
    _bounded_nonce(job_nonce)
    if executor_identity is not None:
        _bounded_id(executor_identity, "executor_identity")
    if generation is not None:
        _bounded_id(generation, "generation")
    records = _line_records(segment)
    state = budget if budget is not None else CapabilityBudget.from_limits(limits)
    found: list[dict[str, Any]] = []
    errors: list[str] = []
    violations: list[str] = []
    by_turn: dict[str, int] = {}
    injected = set(injected_lines)
    # Calculate turn multiplicity before admitting any request. A second
    # record for the same executor turn may arrive in a later callback, so a
    # streaming parser must not authorize the first one and discover ambiguity
    # only after the fact.
    turn_attempts: dict[str, int] = {}
    record_attempts: dict[int, int] = {}
    for index, record in enumerate(records):
        if not executor_record(record):
            continue
        content = _filtered_content(record, record_content(record), injected)
        count = sum(1 for line in content.splitlines() if REQUEST_MARKER_SHAPE_RE.fullmatch(line))
        record_attempts[index] = count
        if count:
            turn = _turn_id(record, index)
            turn_attempts[turn] = turn_attempts.get(turn, 0) + count
    for index, record in enumerate(records):
        if not executor_record(record):
            continue
        content = _filtered_content(record, record_content(record), injected)
        if not content:
            continue
        if "CMX_CAPABILITY_DECISION" in content:
            violations.append("executor-decision-shaped-content-ignored")
        requests, parse_errors = request_from_content(content, job_nonce=job_nonce)
        attempt_count = record_attempts.get(index, 0)
        for _ in range(attempt_count):
            status = state.consume_attempt()
            if status != "accepted":
                errors.append(status)
        errors.extend(parse_errors)
        turn = _turn_id(record, index) if attempt_count else None
        if attempt_count > 1 or (turn is not None and turn_attempts.get(turn, 0) > 1):
            if "capability-request-multiple-in-turn" not in errors:
                errors.append("capability-request-multiple-in-turn")
            # A mixed turn is ambiguous even when one of its payloads parses;
            # count every marker above, but do not expose any request from the
            # turn to the authority/decision layer.
            continue
        if state.request_attempts > state.max_request_attempts:
            # Once the hard marker-attempt cap is crossed, no request from the
            # offending turn is eligible for authority, even if its JSON is
            # otherwise valid.
            continue
        if attempt_count:
            turn = _turn_id(record, index)
            by_turn[turn] = by_turn.get(turn, 0) + attempt_count
            invocation_value = _record_identity_value(
                record,
                "capability_invoked", "capabilityInvoked", "capability_execution", "capabilityExecution",
                "capability_invocation", "capabilityInvocation", "tool_call", "tool_calls",
            )
            invoked = invocation_value is True or (
                isinstance(invocation_value, str) and invocation_value.casefold() in {"true", "executed", "invoked"}
            ) or (
                invocation_value not in (None, False, "", [], {})
                and any(key in record for key in ("tool_call", "tool_calls", "capability_invocation", "capabilityInvocation"))
            )
            if invoked or "invoked capability" in content.casefold():
                violations.append("capability-invocation-in-request-turn")
                errors.append("capability-invocation-in-request-turn")
        for request in requests:
            if _record_identity_value(record, "job_nonce", "jobNonce") not in (None, job_nonce) or not _fresh_correlated(record):
                errors.append("capability-request-stale")
                continue
            if not _identity_matches(record, job_nonce=job_nonce, executor_identity=executor_identity, generation=generation):
                # Keep identity and generation failures distinct for operator
                # diagnostics while failing closed either way.
                identity_present = any(key in record for key in ("executor_identity", "executor_session", "session_id"))
                generation_present = any(key in record for key in ("generation", "generation_id"))
                if executor_identity is not None and (not identity_present or any(record.get(key) != executor_identity for key in ("executor_identity", "executor_session", "session_id") if key in record)):
                    errors.append("capability-request-identity-mismatch")
                if generation is not None and (not generation_present or any(record.get(key) != generation for key in ("generation", "generation_id") if key in record)):
                    errors.append("capability-request-generation-mismatch")
                if executor_identity is None and generation is None:
                    errors.append("capability-request-binding-mismatch")
                continue
            # Remember the identity before checking the open-request slot.
            # A valid request blocked by another open request is still an
            # attempt; retrying that same marker after the slot closes must be
            # classified as replay, not admitted as a fresh request.
            if state.remember_request(request["request_id"]):
                errors.append("capability-request-replayed")
                continue
            if state.open_request not in (None, request["request_id"]):
                errors.append("capability-request-open")
                continue
            if state.open(request["request_id"]) != "accepted":
                errors.append("capability-request-open")
                continue
            found.append(request)
    for turn, count in by_turn.items():
        if count > 1:
            # Keep this explicit even if parse errors already recorded; it is
            # the stable reason callers use to fail closed for a mixed turn.
            if "capability-request-multiple-in-turn" not in errors:
                errors.append("capability-request-multiple-in-turn")
    return {
        "requests": found,
        "errors": errors,
        "policy_violations": violations,
        "budget": state.as_json(),
        "status": "capability-request-budget-exhausted" if state.request_attempts > state.max_request_attempts else ("error" if errors else "accepted"),
    }


def capability_decision(
    request: dict[str, Any],
    *,
    job_nonce: str,
    executor_identity: str,
    generation: str,
    decision: str,
    granted_scope: str,
    expires_at: float,
    transcript_cursor: int | None = None,
    now: float | None = None,
    job_deadline: float | None = None,
    manifest: Any | None = None,
    user_authorized: bool = False,
    command_verdict: str | None = None,
) -> dict[str, Any]:
    if not isinstance(decision, str) or decision not in DECISIONS:
        fail("capability-decision-invalid")
    if not isinstance(user_authorized, bool):
        fail("capability-user-authorization-malformed")
    # Validate the request and manifest again at the decision boundary.  The
    # supervisor may not issue a grant for a request/policy that was mutated
    # after it was parsed.
    request = validate_request(request, job_nonce=job_nonce)
    normalized_manifest: dict[str, Any] | None = None
    if manifest is not None:
        normalized_manifest, _, _ = validate_manifest(manifest)
    if not isinstance(executor_identity, str) or not executor_identity:
        fail("executor-identity-malformed")
    if not isinstance(generation, str) or not generation:
        fail("generation-malformed")
    if not finite_number(expires_at):
        fail("capability-decision-expiry-invalid")
    current = time.time() if now is None else now
    if not finite_number(current):
        fail("capability-decision-clock-invalid")
    if job_deadline is not None and not finite_number(job_deadline):
        fail("capability-decision-deadline-invalid")
    policy_decision_seconds = MAX_DECISION_SECONDS
    if normalized_manifest is not None:
        policy_decision_seconds = normalized_manifest["limits"]["max_decision_seconds"]
    upper = min(current + policy_decision_seconds, job_deadline) if job_deadline is not None else current + policy_decision_seconds
    if expires_at <= current or expires_at > upper:
        fail("capability-decision-expiry-out-of-bounds")
    if not isinstance(granted_scope, str):
        fail("granted-scope-malformed")
    try:
        scope_size = len(granted_scope.encode("utf-8"))
    except UnicodeEncodeError:
        fail("granted-scope-malformed")
    if scope_size > MAX_FIELD_LENGTH:
        fail("granted-scope-malformed")
    _control_free(granted_scope)
    if decision == "approve":
        if not granted_scope or granted_scope != request.get("scope"):
            fail("capability-decision-scope-mismatch")
    elif granted_scope:
        # A deny/ask-user envelope must not smuggle a usable grant scope.
        fail("capability-decision-scope-mismatch")

    if decision == "approve":
        kind = request["kind"]
        if kind in {"local_skill", "local_read_only_command"}:
            # Delegated local authority is a supervisor precondition, not an
            # optional check that user authorization can bypass.  User
            # authorization is reserved for capabilities with external
            # effects; a local grant without an explicit manifest delegation
            # would let an absent/none authority silently widen the policy.
            if normalized_manifest is None or normalized_manifest["delegated_capability_authority"] != AUTHORITY_LOCAL_READ_ONLY:
                fail("capability-delegated-authority-missing")
            if request["network"] is not False:
                fail("capability-request-network-invalid")
            if request["side_effects"].casefold() not in {"none", "read-only", "read only", "local-read-only"}:
                fail("capability-local-effect-invalid")
            if "read" not in request["expected_effect"].casefold() or "local" not in request["expected_effect"].casefold():
                fail("capability-local-effect-invalid")
            if LOCAL_SENSITIVE_SCOPE_RE.search(request["scope"]) or LOCAL_SENSITIVE_SCOPE_RE.search(request["expected_effect"]):
                fail("capability-local-scope-invalid")
            if kind == "local_read_only_command" and command_verdict != "routine":
                fail("capability-command-policy-required")
            if not user_authorized and normalized_manifest["decision_mode"] == "parent-user":
                fail("capability-parent-user-authorization-required")
        elif kind in {"network", "external_data"} and request["network"] is not True:
            # A network/external-data capability must declare its egress
            # boundary explicitly; a false flag must not disguise it as a
            # local request.
            fail("capability-request-network-invalid")
        external = request["network"] is True or kind in {"mcp_tool", "network", "external_data"}
        if external:
            # The common supervisor may only approve external data after the
            # parent/user has made the exact egress decision.  This explicit
            # argument prevents a profile or executor from self-authorizing.
            if not user_authorized:
                fail("capability-user-authorization-required")
        else:
            # Local skill/command authority was checked above.  Keep this
            # branch intentionally empty for future non-egress capability
            # kinds so no new kind inherits an implicit grant.
            pass

    cursor = request.get("transcript_cursor", 0) if transcript_cursor is None else transcript_cursor
    if isinstance(cursor, bool) or not isinstance(cursor, int) or cursor < 0 or cursor > 2**63 - 1:
        fail("capability-decision-cursor-invalid")
    if request.get("transcript_cursor") is not None and cursor != request["transcript_cursor"]:
        fail("capability-decision-cursor-mismatch")
    return {
        "schema_version": SCHEMA_VERSION,
        "job_nonce": job_nonce,
        "request_id": request["request_id"],
        "executor_identity": _bounded_id(executor_identity, "executor_identity"),
        "generation": _bounded_id(generation, "generation"),
        "transcript_cursor": cursor,
        "decision": decision,
        "granted_scope": granted_scope,
        "expires_at": expires_at,
    }


def parse_decision_envelope(
    marker: str,
    payload: str,
    *,
    job_nonce: str,
    request: dict[str, Any],
    executor_identity: str,
    generation: str,
    now: float | None = None,
    job_deadline: float | None = None,
    manifest: Any | None = None,
    user_authorized: bool = False,
    command_verdict: str | None = None,
) -> dict[str, Any]:
    request = validate_request(request, job_nonce=job_nonce)
    if not isinstance(marker, str):
        fail("capability-decision-identity-mismatch")
    match = DECISION_MARKER_RE.fullmatch(marker)
    if not match or match.group("nonce") != job_nonce or match.group("request_id") != request.get("request_id"):
        fail("capability-decision-identity-mismatch")
    value = _canonical_line_object(payload, "capability-decision")
    decision_version = value.get("schema_version")
    if not exact_version(decision_version, SCHEMA_VERSION):
        fail("capability-decision-schema-version-skew")
    if set(value) != DECISION_KEYS:
        fail("capability-decision-malformed")
    if value.get("job_nonce") != job_nonce or value.get("request_id") != request.get("request_id"):
        fail("capability-decision-identity-mismatch")
    if value.get("executor_identity") != executor_identity or value.get("generation") != generation:
        fail("capability-decision-binding-mismatch")
    cursor = value.get("transcript_cursor")
    if isinstance(cursor, bool) or not isinstance(cursor, int) or cursor < 0 or cursor > 2**63 - 1:
        fail("capability-decision-cursor-invalid")
    expected_cursor = request.get("transcript_cursor")
    if expected_cursor is not None and cursor != expected_cursor:
        fail("capability-decision-cursor-mismatch")
    return capability_decision(
        request,
        job_nonce=job_nonce,
        executor_identity=executor_identity,
        generation=generation,
        decision=value["decision"],
        granted_scope=value["granted_scope"],
        expires_at=value["expires_at"],
        transcript_cursor=cursor,
        now=now,
        job_deadline=job_deadline,
        manifest=manifest,
        user_authorized=user_authorized,
        command_verdict=command_verdict,
    )


def render_decision_envelope(request: dict[str, Any], **kwargs: Any) -> dict[str, str]:
    """Render the supervisor-only decision transport without granting itself.

    The canonical payload is the only authority-bearing object.  The comment
    marker is returned separately for optional metadata/audit output and must
    never be parsed as authority from executor-authored transcript content.
    """
    decision = capability_decision(request, **kwargs)
    payload = canonical_bytes(decision, allow_controls=False).decode("utf-8")
    marker = f"<!-- CMX_CAPABILITY_DECISION {decision['job_nonce']} {decision['request_id']} -->"
    envelope = "\n".join(("<CMUX_CAPABILITY_DECISION>", payload, "</CMUX_CAPABILITY_DECISION>"))
    return {"envelope": envelope, "marker": marker, "payload": payload}


# Keep a descriptive alias for adapters that call this operation by the
# capability-specific name used in the wire-contract prose.
render_capability_decision = render_decision_envelope


def low_risk_recovery_allowed(
    request: dict[str, Any],
    *,
    command_verdict: str | None = None,
    execution_evidence: bool = False,
    manifest: Any | None = None,
) -> bool:
    """Return whether one undeclared attempt is eligible for one reminder.

    Recovery is intentionally narrower than approval: it requires an explicit
    local/read-only declaration and machine evidence that nothing ran.  A
    missing command verdict is not enough for a command request.
    """
    if not isinstance(execution_evidence, bool) or execution_evidence:
        return False
    kind = request.get("kind")
    if kind not in {"local_skill", "local_read_only_command"}:
        return False
    if request.get("network") is not False:
        return False
    if kind == "local_read_only_command" and command_verdict != "routine":
        return False
    if command_verdict is not None and command_verdict != "routine":
        return False
    if manifest is not None:
        normalized_manifest, _, _ = validate_manifest(manifest)
        authorized = normalized_manifest["initially_authorized"]["skills" if kind == "local_skill" else "tools"]
        if request.get("name") in authorized:
            return False
    side_effects = request.get("side_effects")
    effect = request.get("expected_effect")
    scope = request.get("scope")
    if not isinstance(side_effects, str) or side_effects.casefold() not in {"none", "read-only", "read only", "local-read-only"}:
        return False
    if not isinstance(effect, str) or not isinstance(scope, str):
        return False
    normalized_effect = effect.casefold().replace("_", "-")
    normalized_scope = scope.casefold().replace("_", "-")
    if "read" not in normalized_effect or "local" not in normalized_effect:
        return False
    # A read-only-looking declaration is not enough when either the requested
    # scope or stated effect names an external/network/write boundary.
    # Recovery is narrower than approval and must stay machine-checkable.
    if LOCAL_SENSITIVE_SCOPE_RE.search(normalized_scope) or LOCAL_SENSITIVE_SCOPE_RE.search(normalized_effect):
        return False
    return True


def recovery_action(state: CapabilityBudget, request: dict[str, Any], *, command_verdict: str | None = None, execution_evidence: bool | None = None, manifest: Any | None = None) -> str:
    if not low_risk_recovery_allowed(request, command_verdict=command_verdict, execution_evidence=execution_evidence, manifest=manifest):
        return "capability-violation-stop"
    return state.issue_reminder()


def _result_limitations(value: Any) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or len(value) > 64:
        fail("result-limitations-malformed")
    result: list[str] = []
    for index, item in enumerate(value):
        result.append(_bounded_string(item, f"limitations[{index}]"))
    return result


def _result_report(value: Any) -> Any:
    if value is None:
        return None
    _json_value(value, allow_controls=True)
    try:
        size = len(canonical_bytes(value, allow_controls=True))
    except ProtocolError:
        raise
    if size > TASK_CORE_MAX_BYTES:
        fail("result-report-too-large")
    return value


RESULT_KEYS = {
    "task_contract_version", "task_payload_sha256", "execution_mode", "status",
    "report", "evidence_class", "limitations",
}


def validate_result(
    value: Any,
    *,
    expected_task_digest: str,
    execution_mode: str,
    supervised: bool = False,
    fresh_correlated_evidence: bool = False,
) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail("result-envelope-malformed")
    if not isinstance(execution_mode, str) or execution_mode not in EXECUTION_MODES:
        fail("execution-mode-invalid")
    if not isinstance(supervised, bool) or not isinstance(fresh_correlated_evidence, bool):
        fail("result-validation-flags-malformed")
    if supervised and execution_mode in {"direct_pi", "manual_handoff"}:
        fail("result-supervision-mode-invalid")
    # Report contract skew before any result-shape or hash handling, including
    # unknown extra fields, so callers never silently coerce an unknown version.
    version = value.get("task_contract_version")
    if not exact_version(version, TASK_CONTRACT_VERSION):
        fail("task-contract-version-skew")
    if set(value) - RESULT_KEYS:
        fail("result-envelope-fields")
    if not isinstance(expected_task_digest, str) or not DIGEST_RE.fullmatch(expected_task_digest):
        fail("task-payload-hash-malformed")
    if value.get("execution_mode") != execution_mode:
        fail("result-execution-mode-mismatch")
    digest = value.get("task_payload_sha256")
    if "task_payload_sha256" not in value:
        if execution_mode == "manual_handoff":
            # A user-supplied manual result without a hash is the one
            # documented exception to the result identity requirement. Keep
            # it explicitly unverified; it can never satisfy completion. The
            # exception is intentionally handled before the required valid
            # envelope fields below so an unverified paste can still be shown
            # to the user without being mistaken for a result import.
            limitations = _result_limitations(value.get("limitations"))
            report = _result_report(value.get("report"))
            return {
                "task_contract_version": TASK_CONTRACT_VERSION,
                "status": "unverified",
                "execution_mode": execution_mode,
                "evidence_class": "manual",
                "supervised": False,
                "report": report,
                "limitations": [*limitations, "missing task payload hash"],
            }
        fail("task-payload-hash-missing")
    if not isinstance(digest, str):
        fail("task-payload-hash-malformed")
    if not DIGEST_RE.fullmatch(digest) or digest != expected_task_digest:
        fail("task-payload-hash-mismatch")

    # Every identified result envelope must state its evidence limitations and
    # class explicitly. Do not default either field: omission would erase the
    # distinction between a report that made an assertion and one that did not.
    if "limitations" not in value:
        fail("result-limitations-missing")
    limitations = _result_limitations(value["limitations"])
    if "evidence_class" not in value:
        fail("result-evidence-class-missing")
    evidence_class = value["evidence_class"]
    if not isinstance(evidence_class, str):
        fail("result-evidence-class-mismatch")
    if "status" not in value:
        fail("result-status-missing")
    status = value["status"]
    _bounded_string(status, "result-status")
    report = _result_report(value.get("report"))
    if execution_mode == "manual_handoff":
        if evidence_class not in {"manual", "unsupervised"}:
            fail("manual-evidence-class-invalid")
        if report is None:
            fail("result-report-missing")
        return {
            "task_contract_version": TASK_CONTRACT_VERSION,
            "status": status,
            "execution_mode": execution_mode,
            "evidence_class": "manual",
            "supervised": False,
            "task_payload_sha256": digest,
            "report": report,
            "limitations": limitations,
        }
    expected_class = "supervised" if supervised else "direct"
    if evidence_class != expected_class:
        fail("result-evidence-class-mismatch")
    if supervised and not fresh_correlated_evidence:
        fail("supervised-evidence-missing")
    if report is None:
        fail("result-report-missing")
    return {
        "task_contract_version": TASK_CONTRACT_VERSION,
        "status": status,
        "execution_mode": execution_mode,
        "evidence_class": expected_class,
        "supervised": supervised,
        "task_payload_sha256": digest,
        "report": report,
        "limitations": limitations,
    }


def _contains_key(value: Any, key: str) -> bool:
    """Find a reserved field in nested route/transport data."""
    if isinstance(value, dict):
        return key in value or any(_contains_key(item, key) for item in value.values())
    if isinstance(value, list):
        return any(_contains_key(item, key) for item in value)
    return False


def _contains_text(value: Any, needle: str) -> bool:
    """Find a forbidden digest/name even when an adapter hides it in text."""
    if isinstance(value, str):
        return needle in value
    if isinstance(value, dict):
        return any(_contains_text(key, needle) or _contains_text(item, needle) for key, item in value.items())
    if isinstance(value, list):
        return any(_contains_text(item, needle) for item in value)
    return False


def validate_job_and_brief(job: Any, brief: Any, *, execution_mode: str | None = None) -> dict[str, Any]:
    """Validate the byte-identity boundary between a job and its brief.

    This is deliberately a data-only check. A supervisor may retain expected
    digests in its private state, but neither transmitted object may carry the
    expected manifest digest or silently rewrite the task core. Check nested
    transport/lifecycle metadata as well as top-level fields: route wrappers
    are untrusted adapter data and must not become a digest side channel.
    """
    if not isinstance(job, dict) or not isinstance(brief, dict):
        fail("capability-job-or-brief-malformed")
    if execution_mode is not None and (not isinstance(execution_mode, str) or execution_mode not in EXECUTION_MODES):
        fail("execution-mode-invalid")
    if (
        _contains_key(job, "capability_manifest_sha256")
        or _contains_key(brief, "capability_manifest_sha256")
        or _contains_text(job, "capability_manifest_sha256")
        or _contains_text(brief, "capability_manifest_sha256")
    ):
        fail("capability-manifest-digest-leak")
    for packet, name in ((job, "job"), (brief, "brief")):
        version = packet.get("capability_policy_version")
        if not exact_version(version, CAPABILITY_POLICY_VERSION):
            fail("capability-protocol-version-skew")
        authority = packet.get("delegated_capability_authority")
        if not isinstance(authority, str) or authority not in AUTHORITY_VALUES:
            fail("delegated-capability-authority-invalid")
        if not isinstance(packet.get("capability_manifest"), str) or not isinstance(packet.get("task_core"), str):
            fail(f"{name}-protocol-fields")
        if not isinstance(packet.get("task_payload_sha256"), str) or not DIGEST_RE.fullmatch(packet["task_payload_sha256"]):
            fail("task-payload-hash-malformed")
    assert_manifest_byte_identity(job["capability_manifest"], brief["capability_manifest"])
    assert_task_core_byte_identity(job["task_core"], brief["task_core"])
    manifest = parse_json_value(job["capability_manifest"], "capability-manifest")
    task_core = parse_json_value(job["task_core"], "task-core")
    normalized_manifest, _, manifest_digest = validate_manifest(manifest)
    _, _, task_digest = validate_task_core(task_core)
    # The actual expected manifest digest is private supervisor state too; a
    # route wrapper may not smuggle it as a free-form string instead of a key.
    if _contains_text(job, manifest_digest) or _contains_text(brief, manifest_digest):
        fail("capability-manifest-digest-leak")
    if job["capability_policy_version"] != normalized_manifest["capability_policy_version"] or brief["capability_policy_version"] != normalized_manifest["capability_policy_version"]:
        fail("capability-protocol-version-skew")
    if job["delegated_capability_authority"] != normalized_manifest["delegated_capability_authority"] or brief["delegated_capability_authority"] != normalized_manifest["delegated_capability_authority"]:
        fail("delegated-capability-authority-invalid")
    if job["task_payload_sha256"] != task_digest or brief["task_payload_sha256"] != task_digest:
        fail("task-payload-hash-mismatch")

    # Validate the route envelope independently from the hashed task core.
    # Route metadata is still untrusted adapter input: direct_pi must not gain
    # a profile/transport by mutation, and transport/lifecycle wrappers may not
    # smuggle a second substantive task or manifest copy.
    route = brief.get("route")
    route_mode: str | None = None
    if route is None:
        # An omitted route is the explicit direct-Pi default. Keep this
        # validator usable for the direct report context while rejecting a
        # caller that claims a delegated mode without route metadata.
        route_mode = "direct_pi"
        if execution_mode is not None and execution_mode != route_mode:
            fail("result-execution-mode-mismatch")
    elif not isinstance(route, dict):
        fail("capability-route-fields")
    else:
        if set(route) - ROUTE_KEYS:
            fail("capability-route-fields")
        route_mode = route.get("execution_mode")
        if not isinstance(route_mode, str) or route_mode not in EXECUTION_MODES:
            fail("execution-mode-invalid")
        if route_mode == "direct_pi" and any(key in route for key in ("selected_profile", "transport", "lifecycle")):
            fail("direct-route-metadata")
        if any(
            _contains_key(route.get(key), "task_core")
            or _contains_key(route.get(key), "capability_manifest")
            for key in ("transport", "lifecycle")
        ):
            fail("capability-route-substantive-data")
        # Reuse the route constructor as the single grammar owner. Explicitly
        # reject a present null digest before calling it: null is not a second
        # valid spelling of the optional route hash in received packets.
        if "task_payload_sha256" in route and route.get("task_payload_sha256") is None:
            fail("task-payload-hash-malformed")
        route_envelope(
            route_mode,
            selected_profile=route.get("selected_profile"),
            transport=route.get("transport"),
            lifecycle=route.get("lifecycle"),
            task_payload_sha256=route.get("task_payload_sha256"),
        )
        # The route envelope is unhashed metadata. If it repeats the task
        # digest, it must agree with the validated top-level hash.
        route_digest = route.get("task_payload_sha256")
        if route_digest is not None and route_digest != brief["task_payload_sha256"]:
            fail("task-payload-hash-mismatch")

    if execution_mode is not None:
        if execution_mode not in EXECUTION_MODES:
            fail("execution-mode-invalid")
        if route_mode != execution_mode:
            fail("result-execution-mode-mismatch")
    return {
        "job": job,
        "brief": brief,
        "execution_mode": route_mode,
        "task_payload_sha256": task_digest,
        "capability_manifest_sha256": hashlib.sha256(job["capability_manifest"].encode("utf-8")).hexdigest(),
    }



# Adapter-facing spelling retained alongside the explicit pair validator.
validate_executor_brief = validate_job_and_brief


def render_route_packet(task_core: Any, manifest: Any, *, execution_mode: str | None = None, selected_profile: str | None = None, transport: Any = None, lifecycle: Any = None) -> dict[str, Any]:
    _, core_bytes, task_digest = validate_task_core(task_core)
    _, manifest_bytes, _ = validate_manifest(manifest)
    route = route_envelope(execution_mode, selected_profile=selected_profile, transport=transport, lifecycle=lifecycle, task_payload_sha256=task_digest)
    return {
        "task_core": core_bytes.decode("utf-8"),
        "task_payload_sha256": task_digest,
        "capability_manifest": manifest_bytes.decode("utf-8"),
        # The supervisor keeps the expected manifest digest in its private job
        # state.  It is intentionally not included in a brief/route packet;
        # the executor computes it from the bytes it actually received.
        "route": route,
        "execution_mode": route["execution_mode"],
    }


def render_manual_handoff(task_core: Any, *, user_scope: str | None = None) -> dict[str, str]:
    """Render a user-mediated copy/paste packet without supervisor authority.

    The manual prompt intentionally carries no capability manifest, expected
    manifest digest, job nonce, executor identity, or grant.  It contains only
    the canonical user-approved task core/hash and its scope, so importing a
    later response cannot silently turn it into supervised evidence.
    """
    normalized_core, core_bytes, task_digest = validate_task_core(task_core)
    scope = normalized_core["scope"] if user_scope is None else user_scope
    # Manual routing must preserve the same task-core scope bound; the
    # request-detail 512-byte limit is not applicable to a long approved task
    # contract.
    _bounded_task_core_string(scope, "user_scope")
    if scope != normalized_core["scope"]:
        fail("manual-scope-mismatch", "manual handoff scope must match the canonical task core")
    prompt = "\n".join(
        (
            "<CMUX_MANUAL_HANDOFF>",
            "execution_mode: manual_handoff",
            f"task_core: {core_bytes.decode('utf-8')}",
            f"task_payload_sha256: {task_digest}",
            f"user_approved_scope: {scope}",
            "Return a result with task_contract_version: 1, execution_mode: manual_handoff, task_payload_sha256, report, evidence_class, limitations, and status.",
            "The imported result is manual/unsupervised evidence and must not claim supervised completion.",
            "</CMUX_MANUAL_HANDOFF>",
        )
    )
    return {
        "execution_mode": "manual_handoff",
        "task_core": core_bytes.decode("utf-8"),
        "task_payload_sha256": task_digest,
        "user_scope": scope,
        "prompt": prompt,
    }


def assert_manifest_byte_identity(job_manifest: str, brief_manifest: str) -> str:
    """Validate two transmitted manifest strings and require exact bytes."""
    if not isinstance(job_manifest, str) or not isinstance(brief_manifest, str):
        fail("capability-manifest-propagation-mismatch")
    if job_manifest.encode("utf-8") != brief_manifest.encode("utf-8"):
        fail("capability-manifest-propagation-mismatch")
    _, encoded, _ = validate_manifest(job_manifest)
    if encoded.decode("utf-8") != job_manifest:
        fail("capability-manifest-not-canonical")
    return job_manifest


def assert_task_core_byte_identity(job_core: str, brief_core: str) -> str:
    """Require the supervised/manual task core to be copied byte-for-byte."""
    if not isinstance(job_core, str) or not isinstance(brief_core, str):
        fail("task-core-propagation-mismatch")
    if job_core.encode("utf-8") != brief_core.encode("utf-8"):
        fail("task-core-propagation-mismatch")
    _, encoded, _ = validate_task_core(job_core)
    if encoded.decode("utf-8") != job_core:
        fail("task-core-not-canonical")
    return job_core


def render_capability_reminder(manifest: Any, *, allowed_scope: str | None = None) -> str:
    """Render one non-authoritative recovery reminder without resending task text."""
    _, manifest_bytes, _ = validate_manifest(manifest)
    if allowed_scope is None:
        allowed_scope = "manifest-declared scope only"
    _bounded_string(allowed_scope, "allowed_scope")
    return "\n".join(
        (
            "<CMUX_CAPABILITY_REMINDER>",
            f"capability_manifest: {manifest_bytes.decode('utf-8')}",
            f"allowed_scope: {allowed_scope}",
            "readiness syntax: &lt;!-- CMX_CAPABILITY_READY &lt;job_nonce&gt; --&gt;",
            "readiness payload: <digest-placeholder>",
            "request syntax: &lt;!-- CMX_CAPABILITY_REQUEST &lt;job_nonce&gt; &lt;request_id&gt; --&gt;",
            "request payload: <request-json-placeholder>",
            "decision syntax: &lt;!-- CMX_CAPABILITY_DECISION &lt;job_nonce&gt; &lt;request_id&gt; --&gt;",
            "decision payload: <decision-json-placeholder>",
            "Use the request route for any expansion; this reminder grants no authority and repeats no task text.",
            "</CMUX_CAPABILITY_REMINDER>",
        )
    )


def render_executor_brief(
    task_core: Any,
    manifest: Any,
    *,
    execution_mode: str,
    selected_profile: str | None = None,
    transport: Any = None,
    lifecycle: Any = None,
) -> dict[str, Any]:
    """Render one route packet used as both job payload and executor brief.

    The returned object intentionally contains no expected manifest digest;
    that digest belongs in supervisor state and is only compared with the
    executor's fresh readiness record.
    """
    if execution_mode is None or execution_mode == "" or execution_mode == "direct_pi":
        fail("direct-route-has-no-executor-brief")
    if execution_mode == "manual_handoff":
        # Manual handoff is deliberately manifest-free and has its own
        # copyable-prompt renderer. Never route it through the executor brief,
        # whose packet is allowed to carry delegated capability policy.
        fail("manual-route-has-no-executor-brief")
    packet = render_route_packet(
        task_core,
        manifest,
        execution_mode=execution_mode,
        selected_profile=selected_profile,
        transport=transport,
        lifecycle=lifecycle,
    )
    job = {
        "capability_policy_version": json.loads(packet["capability_manifest"])["capability_policy_version"],
        "delegated_capability_authority": json.loads(packet["capability_manifest"])["delegated_capability_authority"],
        "capability_manifest": packet["capability_manifest"],
        "task_core": packet["task_core"],
        "task_payload_sha256": packet["task_payload_sha256"],
    }
    brief = {
        "capability_policy_version": job["capability_policy_version"],
        "delegated_capability_authority": job["delegated_capability_authority"],
        "capability_manifest": packet["capability_manifest"],
        "task_core": packet["task_core"],
        "task_payload_sha256": packet["task_payload_sha256"],
        "route": packet["route"],
    }
    validate_job_and_brief(job, brief, execution_mode=execution_mode)
    brief["prompt"] = "\n".join(
        (
            "<CMUX_EXECUTOR_BRIEF>",
            f"capability_policy_version: {job['capability_policy_version']}",
            f"delegated_capability_authority: {job['delegated_capability_authority']}",
            f"capability_manifest: {job['capability_manifest']}",
            f"task_core: {job['task_core']}",
            f"task_payload_sha256: {job['task_payload_sha256']}",
            f"route: {json.dumps(packet['route'], ensure_ascii=False, sort_keys=True, separators=(',', ':'))}",
            "readiness syntax: &lt;!-- CMX_CAPABILITY_READY &lt;job_nonce&gt; --&gt;",
            "readiness payload: <digest-placeholder>",
            "request syntax: &lt;!-- CMX_CAPABILITY_REQUEST &lt;job_nonce&gt; &lt;request_id&gt; --&gt;",
            "request payload: <request-json-placeholder>",
            "decision syntax: &lt;!-- CMX_CAPABILITY_DECISION &lt;job_nonce&gt; &lt;request_id&gt; --&gt;",
            "decision payload: <decision-json-placeholder>",
            "decision syntax is audit-only in executor text; supervisor decisions arrive through the explicit authority envelope.",
            "</CMUX_EXECUTOR_BRIEF>",
        )
    )
    return {"job": job, "brief": brief, "supervisor_state": {"capability_manifest_sha256": hashlib.sha256(job["capability_manifest"].encode("utf-8")).hexdigest(), "task_payload_sha256": job["task_payload_sha256"]}}


def emit_result(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    manifest = sub.add_parser("manifest")
    manifest.add_argument("--input", required=True, help="JSON text or @path")
    task = sub.add_parser("task-core")
    task.add_argument("--input", required=True, help="JSON text or @path")
    digests = sub.add_parser("digests")
    digests.add_argument("--manifest", required=True)
    digests.add_argument("--task-core", required=True)
    ready = sub.add_parser("readiness")
    ready.add_argument("--segment", required=True)
    ready.add_argument("--job-nonce", required=True)
    ready.add_argument("--manifest", required=True)
    ready.add_argument("--task-core", required=True)
    ready.add_argument("--executor-identity")
    ready.add_argument("--generation")
    request = sub.add_parser("requests")
    request.add_argument("--segment", required=True)
    request.add_argument("--job-nonce", required=True)
    request.add_argument("--executor-identity")
    request.add_argument("--generation")
    brief = sub.add_parser("brief")
    brief.add_argument("--manifest", required=True)
    brief.add_argument("--task-core", required=True)
    brief.add_argument("--execution-mode", required=True, choices=sorted(EXECUTION_MODES))
    brief.add_argument("--selected-profile")
    manual = sub.add_parser("manual-prompt")
    manual.add_argument("--task-core", required=True)
    manual.add_argument("--user-scope")
    reminder = sub.add_parser("reminder")
    reminder.add_argument("--manifest", required=True)
    reminder.add_argument("--allowed-scope")
    result = sub.add_parser("result")
    result.add_argument("--input", required=True)
    result.add_argument("--expected-task-digest", required=True)
    result.add_argument("--execution-mode", required=True, choices=sorted(EXECUTION_MODES))
    result.add_argument("--supervised", action="store_true")
    result.add_argument("--fresh-correlated-evidence", action="store_true")
    args = parser.parse_args()
    try:
        if args.command in {"manifest", "task-core"}:
            value = parse_json_file(args.input[1:], args.command) if args.input.startswith("@") else parse_json_value(args.input, args.command)
            normalized, encoded, digest = validate_manifest(value) if args.command == "manifest" else validate_task_core(value)
            emit_result({"canonical": encoded.decode("utf-8"), "sha256": digest, "bytes": len(encoded), "value": normalized})
        elif args.command == "digests":
            manifest_value = parse_json_file(args.manifest[1:], "manifest") if args.manifest.startswith("@") else parse_json_value(args.manifest, "manifest")
            task_value = parse_json_file(args.task_core[1:], "task-core") if args.task_core.startswith("@") else parse_json_value(args.task_core, "task-core")
            emit_result(digest_record(manifest_value, task_value))
        elif args.command == "readiness":
            segment = pathlib.Path(args.segment).read_text(encoding="utf-8")
            manifest_value = parse_json_file(args.manifest[1:], "manifest") if args.manifest.startswith("@") else parse_json_value(args.manifest, "manifest")
            task_value = parse_json_file(args.task_core[1:], "task-core") if args.task_core.startswith("@") else parse_json_value(args.task_core, "task-core")
            emit_result(parse_readiness(segment, job_nonce=args.job_nonce, manifest=manifest_value, task_core=task_value, executor_identity=args.executor_identity, generation=args.generation))
        elif args.command == "requests":
            segment = pathlib.Path(args.segment).read_text(encoding="utf-8")
            emit_result(parse_requests(segment, job_nonce=args.job_nonce, executor_identity=args.executor_identity, generation=args.generation))
        elif args.command == "brief":
            manifest_value = parse_json_file(args.manifest[1:], "manifest") if args.manifest.startswith("@") else parse_json_value(args.manifest, "manifest")
            task_value = parse_json_file(args.task_core[1:], "task-core") if args.task_core.startswith("@") else parse_json_value(args.task_core, "task-core")
            emit_result(render_executor_brief(task_value, manifest_value, execution_mode=args.execution_mode, selected_profile=args.selected_profile))
        elif args.command == "manual-prompt":
            task_value = parse_json_file(args.task_core[1:], "task-core") if args.task_core.startswith("@") else parse_json_value(args.task_core, "task-core")
            emit_result(render_manual_handoff(task_value, user_scope=args.user_scope))
        elif args.command == "reminder":
            manifest_value = parse_json_file(args.manifest[1:], "manifest") if args.manifest.startswith("@") else parse_json_value(args.manifest, "manifest")
            emit_result({"reminder": render_capability_reminder(manifest_value, allowed_scope=args.allowed_scope)})
        elif args.command == "result":
            value = parse_json_file(args.input[1:], "result") if args.input.startswith("@") else parse_json_value(args.input, "result")
            emit_result(validate_result(value, expected_task_digest=args.expected_task_digest, execution_mode=args.execution_mode, supervised=args.supervised, fresh_correlated_evidence=args.fresh_correlated_evidence))
        return 0
    except ProtocolError as exc:
        print(json.dumps({"status": "error", "reason": exc.code, "message": str(exc)}, separators=(",", ":")), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
