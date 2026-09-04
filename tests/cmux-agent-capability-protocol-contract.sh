#!/usr/bin/env bash
# Deterministic offline fixtures for the CLI-neutral capability protocol.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
protocol="$root/tools/cmux-agent-capability-protocol.py"
[[ -x "$protocol" ]]
python3 -m py_compile "$protocol"

python3 - "$protocol" <<'PY'
from __future__ import annotations
import hashlib
import json
import runpy
import sys

p = runpy.run_path(sys.argv[1], run_name="capability_protocol_fixture")
ProtocolError = p["ProtocolError"]
manifest_fn = p["validate_manifest"]
core_fn = p["validate_task_core"]
route_fn = p["render_route_packet"]
ready_fn = p["parse_readiness"]
requests_fn = p["parse_requests"]
Budget = p["CapabilityBudget"]
decision_fn = p["capability_decision"]
decision_parse_fn = p["parse_decision_envelope"]
recovery_fn = p["recovery_action"]
result_fn = p["validate_result"]
precedence_fn = p["marker_precedence"]
manual_fn = p["render_manual_handoff"]
reminder_fn = p["render_capability_reminder"]

manifest = {
    "capability_policy_version": 1,
    "delegated_capability_authority": "local-read-only",
    "discovery": {"local_skill_metadata": "local", "mcp_metadata": "cached"},
    "initially_authorized": {
        "skills": ["jira-mr-read"],
        "tools": [],
        "mcp_servers": [],
        "mcp_tools": [],
        "network_targets": [],
        "write_scope": [],
    },
    "decision_mode": "supervisor-or-parent-user",
    "limits": {
        "max_request_attempts": 3,
        "max_open_requests": 1,
        "max_reminders": 1,
        "max_decision_seconds": 60,
    },
}
core = {
    "task_contract_version": 1,
    "task_id": "cmx006-fixture",
    "task_text": "Inspect the declared local target and report evidence.\nKeep the approved text exact.",
    "target": "local capability contract fixtures",
    "context": {"repository": "cmux-integration", "notes": "offline deterministic fixture"},
    "scope": "declared checkout and focused contract files only",
    "acceptance_criteria": "Return labeled report evidence without external access.",
    "response_schema": {"status": "string", "evidence": "array", "limitations": "array"},
}

_, manifest_bytes, manifest_hash = manifest_fn(manifest)
_, core_bytes, task_hash = core_fn(core)
assert manifest_bytes.decode() == json.dumps(manifest, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
assert manifest_hash == hashlib.sha256(manifest_bytes).hexdigest()
assert task_hash == hashlib.sha256(core_bytes).hexdigest()
assert b"execution_mode" not in core_bytes

# All three routes carry exactly one task core/hash and manifest; only the
# unhashed route envelope differs.
routes = [route_fn(core, manifest, execution_mode=mode, selected_profile=None if mode == "direct_pi" else "cursor") for mode in ("direct_pi", "supervised_cli_refresh", "manual_handoff")]
assert len({route["task_core"] for route in routes}) == 1
assert len({route["task_payload_sha256"] for route in routes}) == 1
assert len({route["capability_manifest"] for route in routes}) == 1
assert {route["execution_mode"] for route in routes} == {"direct_pi", "supervised_cli_refresh", "manual_handoff"}
assert all("execution_mode" not in json.loads(route["task_core"]) for route in routes)
assert "selected_profile" not in routes[0]["route"]
assert "capability_manifest_sha256" not in routes[0]
default_route = p["route_envelope"]()
assert default_route == {"execution_mode": "direct_pi"}
try:
    p["route_envelope"]("")
except ProtocolError as exc:
    assert exc.code == "execution-mode-invalid"
else:
    raise AssertionError("an explicitly empty route silently selected direct Pi")
try:
    p["route_envelope"](None, selected_profile="cursor")
except ProtocolError as exc:
    assert exc.code == "direct-route-metadata"
else:
    raise AssertionError("direct route accepted profile metadata")
manual = manual_fn(core)
assert manual["task_payload_sha256"] == task_hash
assert manual["execution_mode"] == "manual_handoff"
assert "capability_manifest" not in manual["prompt"]
assert "capability_manifest_sha256" not in manual["prompt"]
assert "job_nonce" not in manual["prompt"]
assert "\n" in manual["prompt"]
reminder = reminder_fn(manifest, allowed_scope="local cached metadata")
assert "task_text" not in reminder and "&lt;!-- CMX_CAPABILITY_REQUEST &lt;job_nonce&gt;" in reminder
assert "&lt;!-- CMX_CAPABILITY_READY &lt;job_nonce&gt; --&gt;" in reminder
assert "&lt;!-- CMX_CAPABILITY_DECISION &lt;job_nonce&gt; &lt;request_id&gt; --&gt;" in reminder
assert "capability_manifest" in reminder
brief = p["render_executor_brief"](core, manifest, execution_mode="supervised_cli_refresh", selected_profile="cursor")
assert brief["job"]["capability_manifest"] == brief["brief"]["capability_manifest"]
assert brief["job"]["task_core"] == brief["brief"]["task_core"]
assert p["validate_job_and_brief"](brief["job"], brief["brief"], execution_mode="supervised_cli_refresh")["task_payload_sha256"] == task_hash
try:
    p["render_executor_brief"](core, manifest, execution_mode="manual_handoff", selected_profile="cursor")
except ProtocolError as exc:
    assert exc.code == "manual-route-has-no-executor-brief"
else:
    raise AssertionError("manual handoff was rendered through the manifest-bearing executor brief")
# A packet without route metadata remains the direct-Pi default; it must not
# invent a profile or delegated transport.
direct_packets = {key: brief["job"][key] for key in ("capability_policy_version", "delegated_capability_authority", "capability_manifest", "task_core", "task_payload_sha256")}
assert p["validate_job_and_brief"](direct_packets, dict(direct_packets))["execution_mode"] == "direct_pi"
assert "capability_manifest_sha256" not in brief["brief"]
assert "&lt;!-- CMX_CAPABILITY_READY &lt;job_nonce&gt; --&gt;" in brief["brief"]["prompt"]
# Expected manifest digests cannot hide inside route metadata, and a repeated
# route task hash must match the top-level hash.
leaked = {"job": brief["job"], "brief": {**brief["brief"], "route": {**brief["brief"]["route"], "transport": {"capability_manifest_sha256": manifest_hash}}}}
try:
    p["validate_job_and_brief"](leaked["job"], leaked["brief"], execution_mode="supervised_cli_refresh")
except ProtocolError as exc:
    assert exc.code == "capability-manifest-digest-leak"
else:
    raise AssertionError("nested expected manifest digest leaked through route metadata")
value_leaked = {**brief["brief"], "route": {**brief["brief"]["route"], "notes": f"expected={manifest_hash}"}}
try:
    p["validate_job_and_brief"](brief["job"], value_leaked, execution_mode="supervised_cli_refresh")
except ProtocolError as exc:
    assert exc.code == "capability-manifest-digest-leak"
else:
    raise AssertionError("expected manifest digest leaked as route text")
route_hash_mismatch = {**brief["brief"], "route": {**brief["brief"]["route"], "task_payload_sha256": "0" * 64}}
try:
    p["validate_job_and_brief"](brief["job"], route_hash_mismatch, execution_mode="supervised_cli_refresh")
except ProtocolError as exc:
    assert exc.code == "task-payload-hash-mismatch"
else:
    raise AssertionError("route task hash mismatch was accepted")
direct_route = route_fn(core, manifest, execution_mode="direct_pi")["route"]
try:
    p["validate_job_and_brief"](
        {"capability_policy_version": 1, "delegated_capability_authority": "local-read-only", "capability_manifest": brief["job"]["capability_manifest"], "task_core": brief["job"]["task_core"], "task_payload_sha256": task_hash},
        {"capability_policy_version": 1, "delegated_capability_authority": "local-read-only", "capability_manifest": brief["brief"]["capability_manifest"], "task_core": brief["brief"]["task_core"], "task_payload_sha256": task_hash, "route": {**direct_route, "selected_profile": "cursor"}},
        execution_mode="direct_pi",
    )
except ProtocolError as exc:
    assert exc.code == "direct-route-metadata"
else:
    raise AssertionError("mutated direct route accepted executor metadata")
assert "&lt;!-- CMX_CAPABILITY_REQUEST &lt;job_nonce&gt; &lt;request_id&gt; --&gt;" in brief["brief"]["prompt"]
assert "capability_manifest_sha256" not in brief["brief"]["prompt"]
assert precedence_fn("<!-- GOAL_COMPLETE -->\n<!-- CMX_CAPABILITY_REQUEST nonce-006 req-jira-1 -->") == "GOAL_COMPLETE"
assert precedence_fn("<!-- ERROR --> bad\n<!-- GOAL_COMPLETE -->") == "ERROR"
assert precedence_fn("<!-- NEED_APPROVAL --> review\n<!-- QUESTION --> clarify") == "NEED_APPROVAL"
assert precedence_fn("<!-- GOAL_COMPLETE -->\n<!-- NEED_APPROVAL --> review") == "NEED_APPROVAL"
assert precedence_fn("<!-- GOAL_COMPLETE -->\n<!-- QUESTION --> clarify") == "QUESTION"

# Bounds and version skew fail closed without truncating user content.
try:
    core_fn({**core, "task_text": "x" * 20000})
except ProtocolError as exc:
    assert exc.code == "task-core-too-large"
else:
    raise AssertionError("oversize task core was accepted")
# The aggregate core bound, not the 512-byte request-detail bound, governs
# long user-approved scope/acceptance text. Unsafe C0 controls still fail.
long_core = {**core, "scope": "scope " + "x" * 900, "acceptance_criteria": "accept " + "y" * 900}
long_normalized, long_bytes, long_hash = core_fn(long_core)
assert long_hash == hashlib.sha256(long_bytes).hexdigest()
try:
    core_fn({**core, "task_text": "safe\x00text"})
except ProtocolError as exc:
    assert exc.code == "control-character"
else:
    raise AssertionError("NUL in task core was accepted")
for bad in (
    {**core, "task_contract_version": 2},
    {**core, "task_contract_version": None},
    {key: value for key, value in core.items() if key != "task_contract_version"},
    {**core, "execution_mode": "manual_handoff"},
):
    try:
        core_fn(bad)
    except ProtocolError as exc:
        assert exc.code in {"task-contract-version-skew", "task-core-route-metadata"}
    else:
        raise AssertionError("task core skew/route metadata was accepted")
for bad_manifest in (
    {**manifest, "capability_policy_version": 2},
    {**manifest, "capability_policy_version": 1.0},
    {key: value for key, value in manifest.items() if key != "capability_policy_version"},
):
    try:
        manifest_fn(bad_manifest)
    except ProtocolError as exc:
        assert exc.code == "capability-protocol-version-skew"
    else:
        raise AssertionError("manifest version skew was accepted")
try:
    manifest_fn({**manifest, "initially_authorized": {**manifest["initially_authorized"], "skills": ["x" * 5000]}})
except ProtocolError as exc:
    assert exc.code in {"initially_authorized.skills[0]-malformed", "capability-manifest-too-large"}
else:
    raise AssertionError("oversize manifest field was accepted")

# Readiness requires an executor role, active nonce/identity, exactly one
# canonical one-line payload, and both exact digests. Injected/non-executor
# echoes are ignored.
ready_payload = json.dumps({"schema_version": 1, "manifest_sha256": manifest_hash, "task_payload_sha256": task_hash}, sort_keys=True, separators=(",", ":"))
ready = f"<!-- CMX_CAPABILITY_READY nonce-006 -->\n{ready_payload}"
segment = [
    {"role": "user", "content": ready, "injected": True},
    {"role": "assistant", "source": "pane", "executor_identity": "cursor-session", "generation": "gen-006", "content": ready},
    {"role": "assistant", "content": "<!-- CMX_CAPABILITY_READY nonce-006 -->\n" + json.dumps({"schema_version": 1, "manifest_sha256": "0" * 64, "task_payload_sha256": "0" * 64}, sort_keys=True, separators=(",", ":")), "injected": True},
    {"role": "assistant", "executor_identity": "cursor-session", "generation": "gen-006", "content": ready},
]
found = ready_fn(segment, job_nonce="nonce-006", manifest=manifest, task_core=core, executor_identity="cursor-session", generation="gen-006")
assert found["payload"]["manifest_sha256"] == manifest_hash
try:
    ready_fn([{"role": "assistant", "executor_identity": "cursor-session", "generation": "gen-006", "content": "<!-- CMX_CAPABILITY_READY nonce-006 trailing -->\\n" + ready_payload}], job_nonce="nonce-006", manifest=manifest, task_core=core, executor_identity="cursor-session", generation="gen-006")
except ProtocolError as exc:
    assert exc.code in {"capability-ready-mismatch", "capability-ready-missing"}
else:
    raise AssertionError("malformed readiness marker was accepted")
try:
    ready_fn([{"role": "assistant", "content": ready}], job_nonce="nonce-006", manifest=manifest, task_core=core, executor_identity="cursor-session", generation="gen-006")
except ProtocolError as exc:
    assert exc.code in {"capability-ready-mismatch", "capability-ready-missing"}
else:
    raise AssertionError("unbound readiness was accepted")
for bad in (
    [{"role": "assistant", "executor_identity": "other", "generation": "gen-006", "content": ready}],
    [{"role": "assistant", "executor_identity": "cursor-session", "generation": "gen-006", "content": ready}, {"role": "tool", "executor_identity": "cursor-session", "generation": "gen-006", "content": ready}],
):
    try:
        ready_fn(bad, job_nonce="nonce-006", manifest=manifest, task_core=core, executor_identity="cursor-session", generation="gen-006")
    except ProtocolError as exc:
        assert exc.code in {"capability-ready-mismatch", "capability-ready-duplicate", "capability-ready-missing"}
    else:
        raise AssertionError("invalid readiness was accepted")

# Requests cover a local Jira/MR skill and a scoped Sourcegraph MCP request.
local_request = {
    "schema_version": 1, "job_nonce": "nonce-006", "request_id": "req-jira-1",
    "kind": "local_skill", "name": "jira-mr-read", "scope": "local cached MR metadata",
    "reason": "need the declared review metadata", "expected_effect": "read-only local lookup",
    "side_effects": "none", "network": False, "max_duration_seconds": 30,
}
mcp_request = {
    "schema_version": 1, "job_nonce": "nonce-006", "request_id": "req-sourcegraph-1",
    "kind": "mcp_tool", "name": "search", "server": "sourcegraph", "tool": "search",
    "scope": "repository:cmux-integration path:src", "reason": "check a declared consumer",
    "expected_effect": "read-only remote query", "side_effects": "network data access",
    "network": True, "max_duration_seconds": 20,
}
network_request = {
    "schema_version": 1, "job_nonce": "nonce-006", "request_id": "req-network-1",
    "kind": "network", "name": "https://example.invalid/read-only",
    "scope": "GET https://example.invalid/read-only", "reason": "user-approved remote check",
    "expected_effect": "read-only remote query", "side_effects": "network data access",
    "network": True, "max_duration_seconds": 20,
}
assert p["validate_request"](network_request, job_nonce="nonce-006")["name"].startswith("https://")
def request_content(value):
    marker = f"<!-- CMX_CAPABILITY_REQUEST nonce-006 {value['request_id']} -->"
    return marker + "\n" + json.dumps(value, sort_keys=True, separators=(",", ":"))
segment = [
    {"role": "user", "content": request_content(local_request), "injected": True},
    {"role": "assistant", "source": "pane", "executor_identity": "cursor-session", "generation": "gen-006", "turn_id": "pane-turn", "content": request_content(local_request)},
    {"role": "assistant", "executor_identity": "cursor-session", "generation": "gen-006", "turn_id": "turn-1", "content": request_content(local_request)},
    {"role": "assistant", "executor_identity": "cursor-session", "generation": "gen-006", "turn_id": "turn-3", "content": request_content(local_request)},
    {"role": "assistant", "executor_identity": "cursor-session", "generation": "gen-006", "turn_id": "turn-2", "content": request_content(mcp_request)},
    {"role": "system", "content": "<!-- CMX_CAPABILITY_REQUEST nonce-006 ignored -->\n{}"},
]
parsed = requests_fn(segment, job_nonce="nonce-006", executor_identity="cursor-session", generation="gen-006")
assert [item["request_id"] for item in parsed["requests"]] == ["req-jira-1"]
assert "capability-request-replayed" in parsed["errors"]
assert parsed["budget"]["request_attempts"] == 3
multiple_turn = requests_fn([{
    "role": "assistant", "executor_identity": "cursor-session", "generation": "gen-006", "turn_id": "same-turn",
    "content": request_content(local_request),
}, {
    "role": "assistant", "executor_identity": "cursor-session", "generation": "gen-006", "turn_id": "same-turn",
    "content": request_content(mcp_request),
}], job_nonce="nonce-006", executor_identity="cursor-session", generation="gen-006")
assert not multiple_turn["requests"]
assert "capability-request-multiple-in-turn" in multiple_turn["errors"]

limited = requests_fn([{"role": "assistant", "executor_identity": "cursor-session", "generation": "gen-006", "content": request_content(local_request)}], job_nonce="nonce-006", executor_identity="cursor-session", generation="gen-006", limits={"max_request_attempts": 0, "max_open_requests": 1, "max_reminders": 1})
assert limited["status"] == "capability-request-budget-exhausted" and not limited["requests"]
# Replaying the same valid marker in a later transcript callback is rejected
# even while the original request remains open.
replay_state = Budget()
first = requests_fn([{"role": "assistant", "executor_identity": "cursor-session", "generation": "gen-006", "turn_id": "replay-1", "content": request_content(local_request)}], job_nonce="nonce-006", executor_identity="cursor-session", generation="gen-006", budget=replay_state)
assert len(first["requests"]) == 1
second = requests_fn([{"role": "assistant", "executor_identity": "cursor-session", "generation": "gen-006", "turn_id": "replay-2", "content": request_content(local_request)}], job_nonce="nonce-006", executor_identity="cursor-session", generation="gen-006", budget=replay_state)
assert not second["requests"] and "capability-request-replayed" in second["errors"]
# Whitespace-wrapped malformed markers are still marker attempts.
wrapped = requests_fn([{"role": "assistant", "executor_identity": "cursor-session", "generation": "gen-006", "content": "  <!-- CMX_CAPABILITY_REQUEST nonce-006 wrapped -->\nnot-json"}], job_nonce="nonce-006", executor_identity="cursor-session", generation="gen-006")
assert wrapped["budget"]["request_attempts"] == 1 and not wrapped["requests"]

# Every attempt consumes budget, including malformed/stale attempts; a fourth
# attempt receives the distinct exhausted status.
malformed = "\n".join([
    "<!-- CMX_CAPABILITY_REQUEST old-nonce stale -->\n{}".format(json.dumps(local_request, sort_keys=True, separators=(",", ":"))),
    "<!-- CMX_CAPABILITY_REQUEST nonce-006 bad -->\nnot-json",
    "<!-- CMX_CAPABILITY_REQUEST nonce-006 bad2 -->\nnot-json",
    "<!-- CMX_CAPABILITY_REQUEST nonce-006 bad3 -->\nnot-json",
])
parsed = requests_fn([{"role": "assistant", "executor_identity": "cursor-session", "generation": "gen-006", "content": malformed}], job_nonce="nonce-006", executor_identity="cursor-session", generation="gen-006")
assert parsed["budget"]["request_attempts"] == 4
assert parsed["status"] == "capability-request-budget-exhausted"
assert "capability-request-stale" in parsed["errors"]

# Decision authority, exact scope, nonce/request/session/generation/cursor
# binding, and bounded expiry.
local_request["transcript_cursor"] = 42
approved = decision_fn(local_request, job_nonce="nonce-006", executor_identity="cursor-session", generation="gen-006", decision="approve", granted_scope=local_request["scope"], expires_at=150, transcript_cursor=42, now=100, job_deadline=200, manifest=manifest)
# Delegated local-read-only authority permits an exact negotiated expansion;
# the initial lists describe no-request capabilities, not an immutable ceiling.
expanded = {**local_request, "request_id": "req-new-skill", "name": "new-local-skill"}
assert decision_fn(expanded, job_nonce="nonce-006", executor_identity="cursor-session", generation="gen-006", decision="approve", granted_scope=expanded["scope"], expires_at=150, transcript_cursor=42, now=100, job_deadline=200, manifest=manifest)["decision"] == "approve"
try:
    decision_fn({**expanded, "request_id": "req-local-network", "scope": "local network metadata"}, job_nonce="nonce-006", executor_identity="cursor-session", generation="gen-006", decision="approve", granted_scope="local network metadata", expires_at=150, transcript_cursor=42, now=100, job_deadline=200, manifest=manifest)
except ProtocolError as exc:
    assert exc.code == "capability-local-scope-invalid"
else:
    raise AssertionError("local authority approved an egress-shaped scope")
local_command = {**local_request, "request_id": "req-command-1", "kind": "local_read_only_command", "name": "cat-readme"}
try:
    decision_fn(local_command, job_nonce="nonce-006", executor_identity="cursor-session", generation="gen-006", decision="approve", granted_scope=local_command["scope"], expires_at=150, transcript_cursor=42, now=100, job_deadline=200, manifest=manifest)
except ProtocolError as exc:
    assert exc.code == "capability-command-policy-required"
else:
    raise AssertionError("local command approval bypassed v2 verdict")
assert decision_fn(local_command, job_nonce="nonce-006", executor_identity="cursor-session", generation="gen-006", decision="approve", granted_scope=local_command["scope"], expires_at=150, transcript_cursor=42, now=100, job_deadline=200, manifest=manifest, user_authorized=True, command_verdict="routine")["decision"] == "approve"
marker = "<!-- CMX_CAPABILITY_DECISION nonce-006 req-jira-1 -->"
payload = json.dumps(approved, sort_keys=True, separators=(",", ":"))
assert decision_parse_fn(marker, payload, job_nonce="nonce-006", request=local_request, executor_identity="cursor-session", generation="gen-006", now=100, job_deadline=200, manifest=manifest)["decision"] == "approve"
state = Budget()
assert state.add_grant(approved) == "accepted"
assert state.consume_grant(job_nonce="nonce-006", request_id="req-jira-1", executor_identity="cursor-session", generation="gen-006", transcript_cursor=42, now=120)[0] == "accepted"
assert state.consume_grant(job_nonce="nonce-006", request_id="req-jira-1", executor_identity="cursor-session", generation="gen-006", transcript_cursor=42, now=120)[0] == "capability-grant-replayed"
waiting = Budget()
assert waiting.open("req-user-1") == "accepted"
assert waiting.record_decision("req-user-1", "ask_user") == "accepted"
assert waiting.open_request == "req-user-1"
assert waiting.record_decision("req-user-1", "deny") == "accepted"
assert waiting.open_request is None
assert waiting.expire_ask_user("req-user-1") == "capability-decision-not-pending"
foreign_open = Budget()
assert foreign_open.open("req-open") == "accepted"
assert foreign_open.record_decision("req-other", "deny") == "capability-request-open"
assert foreign_open.open_request == "req-open"
expired = Budget()
assert expired.open("req-user-2") == "accepted"
assert expired.record_decision("req-user-2", "ask_user") == "accepted"
assert expired.expire_ask_user("req-user-2") == "denied-expired"
assert expired.decisions[-1]["decision"] == "deny"
for kwargs, code in [
    ({"decision": "approve", "granted_scope": local_request["scope"], "expires_at": 150, "transcript_cursor": 42, "manifest": {**manifest, "delegated_capability_authority": "none"}}, "capability-delegated-authority-missing"),
    ({"decision": "approve", "granted_scope": local_request["scope"], "expires_at": 150, "transcript_cursor": 42, "manifest": manifest, "request": mcp_request}, "capability-user-authorization-required"),
]:
    request_value = kwargs.pop("request", local_request)
    if request_value is mcp_request:
        kwargs["granted_scope"] = mcp_request["scope"]
    try:
        decision_fn(request_value, job_nonce="nonce-006", executor_identity="cursor-session", generation="gen-006", now=100, job_deadline=200, **kwargs)
    except ProtocolError as exc:
        assert exc.code == code, (exc.code, code)
    else:
        raise AssertionError("unsafe capability approval was accepted")
# Explicit user authorization cannot substitute for the supervisor's
# delegated local-read-only authority. Missing and `none` authority both fail
# closed for local skills even when the caller claims user approval.
for invalid_manifest in (None, {**manifest, "delegated_capability_authority": "none"}):
    for request_value, decision_kwargs in (
        (local_request, {}),
        (local_command, {"command_verdict": "routine"}),
    ):
        try:
            decision_fn(request_value, job_nonce="nonce-006", executor_identity="cursor-session", generation="gen-006", decision="approve", granted_scope=request_value["scope"], expires_at=150, transcript_cursor=42, now=100, job_deadline=200, manifest=invalid_manifest, user_authorized=True, **decision_kwargs)
        except ProtocolError as exc:
            assert exc.code == "capability-delegated-authority-missing"
        else:
            raise AssertionError("user authorization bypassed delegated local authority")
try:
    decision_fn(local_request, job_nonce="nonce-006", executor_identity="cursor-session", generation="gen-006", decision="approve", granted_scope=local_request["scope"], expires_at=161, transcript_cursor=42, now=100, job_deadline=150, manifest=manifest)
except ProtocolError as exc:
    assert exc.code == "capability-decision-expiry-out-of-bounds"
else:
    raise AssertionError("over-deadline decision was accepted")

try:
    Budget(max_request_attempts=4)
except ProtocolError as exc:
    assert exc.code == "max_request_attempts-out-of-bounds"
else:
    raise AssertionError("budget constructor raised the hard request-attempt cap")
budget = Budget()
assert recovery_fn(budget, {**local_request, "side_effects": "none"}, command_verdict="routine", execution_evidence=False) == "accepted"
assert recovery_fn(budget, {**local_request, "side_effects": "none"}, command_verdict="routine", execution_evidence=False) == "capability-reminder-budget-exhausted"
assert recovery_fn(budget, {**local_request, "side_effects": "write", "network": True}, command_verdict="routine", execution_evidence=False) == "capability-violation-stop"
assert not p["low_risk_recovery_allowed"]({**local_request, "kind": "local_read_only_command", "name": "cat", "side_effects": "none"}, command_verdict=None, execution_evidence=False)
assert not p["low_risk_recovery_allowed"]({**local_request, "expected_effect": "read-only local lookup with network disabled"}, command_verdict="routine", execution_evidence=False), "recovery must reject egress-shaped effect text"

# Supervised hash mismatches fail closed. Manual imports are always labeled
# manual/unsupervised and cannot satisfy a supervised completion gate.
base_result = {"task_contract_version": 1, "task_payload_sha256": task_hash, "execution_mode": "supervised_cli_refresh", "status": "GOAL_COMPLETE", "report": "labeled evidence", "evidence_class": "supervised", "limitations": []}
assert result_fn(base_result, expected_task_digest=task_hash, execution_mode="supervised_cli_refresh", supervised=True, fresh_correlated_evidence=True)["evidence_class"] == "supervised"
missing_limitations = {key: value for key, value in base_result.items() if key != "limitations"}
try:
    result_fn(missing_limitations, expected_task_digest=task_hash, execution_mode="supervised_cli_refresh", supervised=True, fresh_correlated_evidence=True)
except ProtocolError as exc:
    assert exc.code == "result-limitations-missing"
else:
    raise AssertionError("supervised result without limitations was accepted")
try:
    result_fn({**base_result, "report": None}, expected_task_digest=task_hash, execution_mode="supervised_cli_refresh", supervised=True, fresh_correlated_evidence=True)
except ProtocolError as exc:
    assert exc.code == "result-report-missing"
else:
    raise AssertionError("missing supervised report was accepted")
try:
    result_fn({**base_result, "task_payload_sha256": "0" * 64}, expected_task_digest=task_hash, execution_mode="supervised_cli_refresh", supervised=True, fresh_correlated_evidence=True)
except ProtocolError as exc:
    assert exc.code == "task-payload-hash-mismatch"
else:
    raise AssertionError("task hash mismatch was accepted")
manual = result_fn({"task_contract_version": 1, "task_payload_sha256": task_hash, "execution_mode": "manual_handoff", "status": "imported", "report": "manual evidence", "evidence_class": "manual", "limitations": []}, expected_task_digest=task_hash, execution_mode="manual_handoff")
assert manual["evidence_class"] == "manual" and manual["supervised"] is False
# Identified direct and manual envelopes must state both metadata fields;
# omission is not equivalent to an explicit empty limitation list or label.
for mode, evidence_class in (("direct_pi", "direct"), ("manual_handoff", "manual")):
    valid = {
        "task_contract_version": 1,
        "task_payload_sha256": task_hash,
        "execution_mode": mode,
        "status": "imported",
        "report": "labeled evidence",
        "evidence_class": evidence_class,
        "limitations": [],
    }
    assert result_fn(valid, expected_task_digest=task_hash, execution_mode=mode)["evidence_class"] == evidence_class
    for field, code in (("limitations", "result-limitations-missing"), ("evidence_class", "result-evidence-class-missing")):
        omitted = {key: value for key, value in valid.items() if key != field}
        try:
            result_fn(omitted, expected_task_digest=task_hash, execution_mode=mode)
        except ProtocolError as exc:
            assert exc.code == code, (mode, field, exc.code, code)
        else:
            raise AssertionError(f"{mode} result without {field} was accepted")
try:
    result_fn({"task_contract_version": 1, "task_payload_sha256": task_hash, "execution_mode": "manual_handoff", "status": "imported", "evidence_class": "manual", "limitations": []}, expected_task_digest=task_hash, execution_mode="manual_handoff")
except ProtocolError as exc:
    assert exc.code == "result-report-missing"
else:
    raise AssertionError("matching manual result without a report was accepted")
missing = result_fn({"task_contract_version": 1, "execution_mode": "manual_handoff"}, expected_task_digest=task_hash, execution_mode="manual_handoff")
assert missing["status"] == "unverified" and missing["evidence_class"] == "manual"
try:
    result_fn({"task_contract_version": 1, "task_payload_sha256": None, "execution_mode": "manual_handoff"}, expected_task_digest=task_hash, execution_mode="manual_handoff")
except ProtocolError as exc:
    assert exc.code == "task-payload-hash-malformed"
else:
    raise AssertionError("malformed manual task hash was treated as missing")
try:
    result_fn({**base_result, "unexpected": "field"}, expected_task_digest=task_hash, execution_mode="supervised_cli_refresh", supervised=True, fresh_correlated_evidence=True)
except ProtocolError as exc:
    assert exc.code == "result-envelope-fields"
else:
    raise AssertionError("unknown result envelope fields were accepted")
try:
    result_fn(base_result, expected_task_digest=task_hash, execution_mode="supervised_cli_refresh", supervised=True, fresh_correlated_evidence=False)
except ProtocolError as exc:
    assert exc.code == "supervised-evidence-missing"
else:
    raise AssertionError("supervised result without fresh evidence was accepted")

print("cmux-agent capability protocol contract: PASS")
PY

# Canonical CLI output is one line and carries stable digests.
manifest='{"capability_policy_version":1,"delegated_capability_authority":"none","decision_mode":"parent-user","discovery":{"local_skill_metadata":"local","mcp_metadata":"cached"},"initially_authorized":{"mcp_servers":[],"mcp_tools":[],"network_targets":[],"skills":[],"tools":[],"write_scope":[]},"limits":{"max_decision_seconds":60,"max_open_requests":1,"max_reminders":1,"max_request_attempts":3}}'
core='{"acceptance_criteria":"report","context":"offline","response_schema":{"status":"string"},"scope":"README.md","target":"README.md","task_contract_version":1,"task_id":"cli-fixture","task_text":"Read README.md"}'
output=$(python3 "$protocol" digests --manifest "$manifest" --task-core "$core")
[[ "$output" != *$'\n'* ]]
grep -Fq 'capability_manifest_sha256' <<<"$output"
grep -Fq 'task_payload_sha256' <<<"$output"

printf '%s\n' 'cmux-agent capability protocol contract: PASS'
