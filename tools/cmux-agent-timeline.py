#!/usr/bin/env python3
"""Record and render a per-job cmux-agent timeline.

The timeline is diagnostic data. It contains event metadata and timestamps,
not prompts, transcript contents, or command output. HTML views are deterministic,
responsive SVG graphs with a watcher-detected state band, observation-reason milestones,
and supervisor-observed event provenance.
"""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import html
import json
import math
import os
import pathlib
import re
import sys
import time
import uuid
from typing import Any, Callable

SCHEMA_VERSION = 1
NONCE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
HANDLE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
EVENT_RE = re.compile(r"^[a-z][a-z0-9_.-]{1,63}$")
DETAIL_KEY_RE = re.compile(r"^[a-z][a-z0-9_.-]{0,63}$")
SOURCES = {"bridge", "cursor", "supervisor", "system", "user", "watcher"}
MAX_VALUE_LENGTH = 512

HTML_SOURCE_COLORS = {
    "supervisor": "#2563eb",
    "watcher": "#d97706",
    "bridge": "#059669",
    "cursor": "#7c3aed",
    "system": "#64748b",
    "user": "#db2777",
}
HTML_STATE_COLORS = {
    "UNKNOWN": "#94a3b8",
    "WORKING": "#60a5fa",
    "REQUIRE_ATTENTION": "#f59e0b",
    "QUESTION": "#f97316",
    "IDLE": "#22c55e",
    "LOST": "#ef4444",
}


def fail(message: str) -> None:
    print(f"cmux-agent timeline: {message}", file=sys.stderr)
    raise SystemExit(2)


def bounded(value: str | None, name: str) -> str | None:
    if value is None:
        return None
    if not value or len(value) > MAX_VALUE_LENGTH or "\n" in value or "\r" in value:
        fail(f"{name} is empty or malformed")
    return value


def required_arg(value: str | None, name: str) -> str:
    value = bounded(value, name)
    if value is None:
        fail(f"{name} is required")
    return value


def identity(args: argparse.Namespace) -> tuple[str, str | None, str | None, str | None]:
    nonce = required_arg(args.job_nonce or os.environ.get("CMUX_AGENT_JOB_NONCE"), "job nonce")
    workspace = bounded(args.workspace or os.environ.get("CMUX_AGENT_WORKSPACE"), "workspace")
    surface = bounded(args.surface or os.environ.get("CMUX_AGENT_SURFACE"), "surface")
    cwd = bounded(args.cwd or os.environ.get("CMUX_AGENT_CWD"), "cwd")
    if not NONCE_RE.fullmatch(nonce):
        fail("job nonce is unsafe")
    if (workspace is None) != (surface is None):
        fail("workspace and surface must be supplied together")
    if workspace is not None:
        if not HANDLE_RE.fullmatch(workspace) or not HANDLE_RE.fullmatch(surface or ""):
            fail("workspace or surface handle is unsafe")
        if workspace == surface:
            fail("workspace and surface mapping is ambiguous")
    if cwd is not None and not pathlib.Path(cwd).is_absolute():
        fail("cwd must be absolute")
    return nonce, workspace, surface, cwd


def timeline_path(value: str) -> pathlib.Path:
    path = pathlib.Path(required_arg(value, "timeline path")).expanduser()
    if not path.is_absolute():
        fail("timeline path must be absolute")
    return path


def timestamp(epoch_ms: int) -> str:
    return dt.datetime.fromtimestamp(epoch_ms / 1000, dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def parse_details(values: list[str]) -> dict[str, str]:
    details: dict[str, str] = {}
    for item in values:
        if "=" not in item:
            fail("timeline detail must use key=value")
        key, value = item.split("=", 1)
        if not DETAIL_KEY_RE.fullmatch(key) or key in details:
            fail("timeline detail key is malformed or duplicated")
        details[key] = required_arg(value, f"detail {key}")
    return details


def record_event(args: argparse.Namespace) -> None:
    path = timeline_path(args.timeline)
    nonce, workspace, surface, cwd = identity(args)
    event_name = required_arg(args.event, "event")
    source = required_arg(args.source, "source")
    if not EVENT_RE.fullmatch(event_name):
        fail("event name is malformed")
    if source not in SOURCES:
        fail("source is unsupported")

    epoch_ms = args.at_ms if args.at_ms is not None else int(time.time() * 1000)
    monotonic_ns = args.monotonic_ns if args.monotonic_ns is not None else time.monotonic_ns()
    if isinstance(epoch_ms, bool) or epoch_ms < 0 or isinstance(monotonic_ns, bool) or monotonic_ns < 0:
        fail("timestamp is malformed")

    value: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "event_id": f"{source}:{monotonic_ns}:{uuid.uuid4().hex[:12]}",
        "job_nonce": nonce,
        "source": source,
        "event": event_name,
        "at": timestamp(epoch_ms),
        "at_ms": epoch_ms,
        "monotonic_ns": monotonic_ns,
    }
    if workspace is not None:
        value["workspace"] = workspace
        value["surface"] = surface
    if cwd is not None:
        value["cwd"] = cwd
    for name in (
        "state",
        "reason",
        "question_id",
        "question_source",
        "question_kind",
        "outcome",
        "status",
    ):
        value_arg = bounded(getattr(args, name), name)
        if value_arg is not None:
            value[name] = value_arg
    if args.quiet_seconds is not None:
        if not math.isfinite(args.quiet_seconds) or args.quiet_seconds < 0:
            fail("quiet seconds must be a finite non-negative number")
        value["quiet_seconds"] = round(args.quiet_seconds, 3)
    value.update(parse_details(args.detail))

    path.parent.mkdir(parents=True, exist_ok=True)
    # Adapters append directly as well; keep one lock name for all writers.
    lock_path = path.with_name(".cmux-agent.timeline.lock")
    line = json.dumps(value, separators=(",", ":"), ensure_ascii=False)
    try:
        with lock_path.open("a+", encoding="utf-8") as lock_stream:
            fcntl.flock(lock_stream.fileno(), fcntl.LOCK_EX)
            with path.open("a", encoding="utf-8") as stream:
                stream.write(line + "\n")
                stream.flush()
    except OSError as exc:
        fail(f"cannot append timeline: {exc}")
    print(line)


def event_at_ms(value: dict[str, Any], line_number: int) -> int:
    raw = value.get("at_ms")
    if isinstance(raw, bool) or not isinstance(raw, int) or raw < 0:
        raw_float = value.get("at")
        if isinstance(raw_float, (int, float)) and not isinstance(raw_float, bool) and raw_float >= 0:
            return int(raw_float * 1000)
        raise ValueError(f"line {line_number}: missing or malformed timestamp")
    return raw


def load_events(path: pathlib.Path) -> tuple[list[dict[str, Any]], str]:
    if not path.is_file():
        fail(f"timeline does not exist: {path}")
    events: list[dict[str, Any]] = []
    nonce: str | None = None
    try:
        with path.open(encoding="utf-8") as stream:
            for line_number, raw in enumerate(stream, 1):
                if not raw.strip():
                    continue
                try:
                    value = json.loads(raw)
                except json.JSONDecodeError as exc:
                    fail(f"malformed JSON at line {line_number}: {exc}")
                if not isinstance(value, dict):
                    fail(f"timeline record at line {line_number} is not an object")
                if value.get("schema_version") != SCHEMA_VERSION:
                    fail(f"timeline record at line {line_number} has an unsupported schema")
                current_nonce = value.get("job_nonce")
                if not isinstance(current_nonce, str) or not NONCE_RE.fullmatch(current_nonce):
                    fail(f"timeline record at line {line_number} has an unsafe nonce")
                if nonce is None:
                    nonce = current_nonce
                elif nonce != current_nonce:
                    fail(f"timeline contains multiple job nonces at line {line_number}")
                event_name = value.get("event")
                source = value.get("source")
                if not isinstance(event_name, str) or not EVENT_RE.fullmatch(event_name):
                    fail(f"timeline record at line {line_number} has a malformed event")
                if source not in SOURCES:
                    fail(f"timeline record at line {line_number} has an unsupported source")
                try:
                    value["_at_ms"] = event_at_ms(value, line_number)
                except ValueError as exc:
                    fail(str(exc))
                value["_line"] = line_number
                events.append(value)
    except OSError as exc:
        fail(f"cannot read timeline: {exc}")
    if not events or nonce is None:
        fail("timeline is empty")
    events.sort(key=lambda value: (value["_at_ms"], value["_line"]))
    return events, nonce


def duration(value: int | None) -> str:
    if value is None:
        return "—"
    if value < 1000:
        return f"{value}ms"
    if value < 60_000:
        return f"{value / 1000:.3f}s"
    minutes, remainder = divmod(value, 60_000)
    return f"{minutes}m {remainder / 1000:.3f}s"


def escaped(value: Any) -> str:
    text = str(value) if value is not None else ""
    return text.replace("|", "\\|").replace("\n", " ").replace("\r", " ")


def question_metrics(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    metrics: list[dict[str, Any]] = []
    active: list[dict[str, Any]] = []
    for value in events:
        event_name = value["event"]
        state = value.get("state")
        is_detection = event_name == "question_detected" or (event_name == "state_changed" and state == "QUESTION")
        if is_detection:
            active.append({"detected": value})
            continue
        if not active:
            continue
        question = active[0]
        if value.get("question_id") and question["detected"].get("question_id") not in (None, value["question_id"]):
            continue
        if (
            event_name == "question_acknowledged"
            or (event_name == "supervisor_observed" and state == "QUESTION")
        ) and "acknowledged" not in question:
            question["acknowledged"] = value
        elif event_name == "question_relayed" and "relayed" not in question:
            question["relayed"] = value
        elif event_name == "decision_received" and "decision" not in question:
            question["decision"] = value
        elif event_name in {"response_sent", "question_resolved"} and "resolved" not in question:
            question["resolved"] = value
            metrics.append(question)
            active.pop(0)
        elif event_name == "state_changed" and state in {"WORKING", "IDLE"} and "resolved" not in question:
            question["resolved"] = value
            question["resolution_source"] = "activity-resumed"
            metrics.append(question)
            active.pop(0)
    metrics.extend(active)
    return metrics


def metric_delta(question: dict[str, Any], end_name: str) -> int | None:
    start = question.get("detected")
    end = question.get(end_name)
    if not start or not end:
        return None
    return max(0, end["_at_ms"] - start["_at_ms"])


def boolean_value(value: Any) -> bool:
    return value is True or (isinstance(value, str) and value.casefold() == "true")


def nonnegative_count(value: Any) -> int | None:
    if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
        return value
    if isinstance(value, str) and value.isdecimal():
        return int(value)
    return None


def first_matching_event(
    events: list[dict[str, Any]], predicate: Callable[[dict[str, Any]], bool]
) -> dict[str, Any] | None:
    for value in events:
        if predicate(value):
            return value
    return None


def first_named_event(events: list[dict[str, Any]], event_name: str, source: str | None = None) -> dict[str, Any] | None:
    return first_matching_event(
        events,
        lambda value: value["event"] == event_name and (source is None or value["source"] == source),
    )


def first_hook_event(
    events: list[dict[str, Any]], predicate: Callable[[dict[str, Any]], bool] | None = None
) -> dict[str, Any] | None:
    return first_matching_event(
        events,
        lambda value: value["event"] == "hook_observed"
        and value["source"] == "bridge"
        and (predicate is None or predicate(value)),
    )


def has_normalized_records(value: dict[str, Any]) -> bool:
    count = nonnegative_count(value.get("normalized_records"))
    return count is not None and count > 0


def observation_milestones(events: list[dict[str, Any]], first_at: int) -> list[dict[str, Any]]:
    selected: list[tuple[str, dict[str, Any], str]] = []

    def add(label: str, value: dict[str, Any] | None, evidence: str) -> None:
        if value is not None:
            selected.append((label, value, evidence))

    def event_evidence(value: dict[str, Any]) -> str:
        hook_name = value.get("hook_event_name")
        suffix = f" ({hook_name})" if hook_name else ""
        return f"{value['source']}/{value['event']}{suffix}"

    add("Surface created", first_named_event(events, "surface_created", "supervisor"), "supervisor/surface_created")
    add("Executor launched", first_named_event(events, "executor_launched", "supervisor"), "supervisor/executor_launched")
    add("Executor ready", first_named_event(events, "executor_ready", "supervisor"), "supervisor/executor_ready")
    add("Prompt submitted", first_named_event(events, "prompt_submitted", "supervisor"), "supervisor/prompt_submitted")
    first_hook = first_hook_event(events)
    add("First hook observed", first_hook, event_evidence(first_hook) if first_hook else "")
    first_path = first_hook_event(events, lambda value: boolean_value(value.get("path_captured")))
    add("Transcript path captured", first_path, event_evidence(first_path) if first_path else "")
    first_normalized = first_hook_event(events, has_normalized_records)
    if first_normalized:
        normalized = nonnegative_count(first_normalized["normalized_records"]) or 0
        add("First normalized record", first_normalized, f"{event_evidence(first_normalized)}; records={normalized}")
    first_working = first_matching_event(
        events,
        lambda value: value["event"] == "state_changed"
        and value["source"] == "watcher"
        and value.get("state") == "WORKING",
    )
    add("Watcher first WORKING", first_working, event_evidence(first_working) if first_working else "")
    add("Completion gate passed", first_named_event(events, "completion_gate_passed", "supervisor"), "supervisor/completion_gate_passed")
    add("Job finished", first_named_event(events, "job_finished", "supervisor"), "supervisor/job_finished")

    selected.sort(key=lambda item: (item[1]["_at_ms"], item[1]["_line"]))
    milestones: list[dict[str, Any]] = []
    previous_at = first_at
    for label, value, evidence in selected:
        at_ms = value["_at_ms"]
        milestones.append(
            {
                "name": label,
                "at": value.get("at", timestamp(at_ms)),
                "at_ms": at_ms,
                "elapsed_ms": max(0, at_ms - first_at),
                "gap_ms": max(0, at_ms - previous_at),
                "evidence": evidence,
            }
        )
        previous_at = at_ms
    return milestones


def as_json(events: list[dict[str, Any]], nonce: str) -> dict[str, Any]:
    first = events[0]["_at_ms"]
    last = events[-1]["_at_ms"]
    states: dict[str, int] = {}
    state_events = [value for value in events if value["event"] == "state_changed" and value.get("state")]
    for index, value in enumerate(state_events):
        next_value = state_events[index + 1] if index + 1 < len(state_events) else None
        end_at = next_value["_at_ms"] if next_value is not None else last
        states[value["state"]] = states.get(value["state"], 0) + max(0, end_at - value["_at_ms"])
    questions = []
    for question in question_metrics(events):
        questions.append(
            {
                "question_source": question["detected"].get("question_source"),
                "detected_to_acknowledged_ms": metric_delta(question, "acknowledged"),
                "detected_to_relayed_ms": metric_delta(question, "relayed"),
                "relayed_to_decision_ms": (
                    max(0, question["decision"]["_at_ms"] - question["relayed"]["_at_ms"])
                    if question.get("decision") and question.get("relayed")
                    else None
                ),
                "decision_to_response_ms": (
                    max(0, question["resolved"]["_at_ms"] - question["decision"]["_at_ms"])
                    if question.get("resolved") and question.get("decision")
                    else None
                ),
                "detected_to_resolved_ms": metric_delta(question, "resolved"),
                "resolved": "resolved" in question,
            }
        )
    clean_events = [{key: item for key, item in value.items() if not key.startswith("_")} for value in events]
    milestones = observation_milestones(events, first)
    prompt_event = first_named_event(events, "prompt_submitted", "supervisor")
    normalized_event = first_hook_event(events, has_normalized_records)
    prompt_to_first_normalized = None
    if prompt_event is not None and normalized_event is not None:
        prompt_to_first_normalized = max(0, normalized_event["_at_ms"] - prompt_event["_at_ms"])
    return {
        "schema_version": SCHEMA_VERSION,
        "job_nonce": nonce,
        "started_at": timestamp(first),
        "finished_at": timestamp(last),
        "total_ms": max(0, last - first),
        "state_durations_ms": states,
        "prompt_to_first_normalized_ms": prompt_to_first_normalized,
        "milestones": milestones,
        "questions": questions,
        "events": clean_events,
    }


def render_markdown(events: list[dict[str, Any]], nonce: str) -> None:
    data = as_json(events, nonce)
    print(f"# cmux-agent timeline\n")
    print(f"- Job: `{nonce}`")
    print(f"- Started: `{data['started_at']}`")
    print(f"- Finished: `{data['finished_at']}`")
    print(f"- Total: **{duration(data['total_ms'])}**")
    print(f"- Events: **{len(events)}**\n")
    print("## Events\n")
    print("| Elapsed | Since previous | Timestamp (UTC) | Source | Event | State/reason |")
    print("| ---: | ---: | --- | --- | --- | --- |")
    first_at = events[0]["_at_ms"]
    previous_at = first_at
    for value in events:
        at = value["_at_ms"]
        state_reason = []
        if value.get("state"):
            state_reason.append(str(value["state"]))
        if value.get("reason"):
            state_reason.append(str(value["reason"]))
        raw_at = value.get("at")
        display_at = timestamp(at) if isinstance(raw_at, (int, float)) else raw_at or timestamp(at)
        print(
            f"| {duration(at - first_at)} | {duration(at - previous_at)} | "
            f"{escaped(display_at)} | {escaped(value['source'])} | "
            f"{escaped(value['event'])} | {escaped(' / '.join(state_reason))} |"
        )
        previous_at = at

    print("\n## State dwell\n")
    if data["state_durations_ms"]:
        print("| State | Duration |\n| --- | ---: |")
        for state, milliseconds in data["state_durations_ms"].items():
            print(f"| {escaped(state)} | {duration(milliseconds)} |")
    else:
        print("No state-change events recorded.")

    print("\n## Observation milestones\n")
    if data["milestones"]:
        print("| Milestone | Elapsed | Gap from previous milestone | Evidence |\n| --- | ---: | ---: | --- |")
        for milestone in data["milestones"]:
            print(
                f"| {escaped(milestone['name'])} | {duration(milestone['elapsed_ms'])} | "
                f"{duration(milestone['gap_ms'])} | {escaped(milestone['evidence'])} |"
            )
    else:
        print("No observation milestones recorded.")
    print(f"\nPrompt → first normalized record: **{duration(data['prompt_to_first_normalized_ms'])}**")

    print("\n## Question handling\n")
    questions = data["questions"]
    if not questions:
        print("No question events recorded.")
        return
    print("| # | Source | Detected → acknowledged | Detected → relayed | Relayed → decision | Decision → response | Detected → resolved |")
    print("| ---: | --- | ---: | ---: | ---: | ---: | ---: |")
    for index, question in enumerate(questions, 1):
        print(
            f"| {index} | {escaped(question.get('question_source') or 'unknown')} | "
            f"{duration(question['detected_to_acknowledged_ms'])} | "
            f"{duration(question['detected_to_relayed_ms'])} | "
            f"{duration(question['relayed_to_decision_ms'])} | "
            f"{duration(question['decision_to_response_ms'])} | "
            f"{duration(question['detected_to_resolved_ms'])} |"
        )


def html_escaped(value: Any) -> str:
    return html.escape(str(value) if value is not None else "", quote=True)


def html_script_json(value: Any) -> str:
    # Keep metadata safe inside the inline JSON script and deterministic across runs.
    return (
        json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
        .replace("&", "\\u0026")
        .replace("<", "\\u003c")
        .replace(">", "\\u003e")
    )


def html_source_order(events: list[dict[str, Any]]) -> list[str]:
    present = {str(value["source"]) for value in events}
    known = [source for source in HTML_SOURCE_COLORS if source in present]
    return known + sorted(present.difference(HTML_SOURCE_COLORS))


def render_html(events: list[dict[str, Any]], nonce: str) -> None:
    data = as_json(events, nonce)
    first_at = events[0]["_at_ms"]
    last_at = events[-1]["_at_ms"]
    total_ms = max(0, last_at - first_at)
    scale_ms = max(1, total_ms)
    plot_left = 190.0
    plot_right = 1340.0
    plot_width = plot_right - plot_left
    sources = html_source_order(events)
    lane_top = 166
    lane_step = 48
    lanes = {source: lane_top + index * lane_step for index, source in enumerate(sources)}
    svg_height = max(236, lane_top + len(sources) * lane_step + 38)

    def x_for(at_ms: int) -> float:
        return plot_left + plot_width * max(0, min(scale_ms, at_ms - first_at)) / scale_ms

    def build_state_spans(event_name: str) -> list[tuple[str, int, int, str]]:
        state_events = [
            value for value in events
            if value["event"] == event_name and value.get("state")
        ]
        spans: list[tuple[str, int, int, str]] = []
        for index, value in enumerate(state_events):
            next_value = state_events[index + 1] if index + 1 < len(state_events) else None
            end_at = next_value["_at_ms"] if next_value is not None else last_at
            reasons = [str(value["reason"])] if value.get("reason") else []
            for observation in events:
                if (
                    observation["event"] == "observation_changed"
                    and observation.get("state") == value.get("state")
                    and value["_at_ms"] <= observation["_at_ms"] < end_at
                    and observation.get("reason")
                    and str(observation["reason"]) not in reasons
                ):
                    reasons.append(str(observation["reason"]))
            spans.append((str(value["state"]), value["_at_ms"], end_at, " → ".join(reasons)))
        return spans

    detected_spans = build_state_spans("state_changed")
    state_track_label = "DETECTED STATE · watcher"
    state_track_y = 38
    svg: list[str] = [
        f'<svg class="timeline-svg" viewBox="0 0 1400 {svg_height}" role="img" '
        'aria-label="cmux-agent event timeline" preserveAspectRatio="xMidYMid meet">',
        '<title>cmux-agent event timeline</title>',
        '<text x="190" y="25" class="section-label">STATE BAND</text>',
        f'<text x="20" y="{state_track_y + 20}" class="state-track-label">{html_escaped(state_track_label)}</text>',
        f'<rect x="190" y="{state_track_y}" width="1150" height="30" rx="8" class="state-track"/>',
    ]
    if detected_spans:
        for state, start_at, end_at, reason in detected_spans:
            x1 = x_for(start_at)
            x2 = x_for(end_at)
            width = max(2.0, x2 - x1)
            color = HTML_STATE_COLORS.get(state, "#94a3b8")
            label = f"{state} · {duration(max(0, end_at - start_at))}"
            tooltip = f"{state_track_label}: {label}" + (f" · {reason}" if reason else "")
            svg.append(
                f'<rect class="state-span" x="{x1:.2f}" y="{state_track_y}" '
                f'width="{width:.2f}" height="30" fill="{color}"><title>{html_escaped(tooltip)}</title></rect>'
            )
            if width >= 110:
                svg.append(
                    f'<text x="{x1 + 8:.2f}" y="{state_track_y + 20}" class="band-label">'
                    f'{html_escaped(label)}</text>'
                )
    else:
        svg.append('<text x="765" y="58" text-anchor="middle" class="band-empty">No watcher state observations recorded</text>')

    svg.append('<text x="190" y="106" class="section-label">EVENT LANES · HOVER OR FOCUS A DOT FOR DETAILS</text>')
    for source in sources:
        y = lanes[source]
        color = HTML_SOURCE_COLORS.get(source, "#64748b")
        svg.extend(
            [
                f'<line x1="190" y1="{y}" x2="1340" y2="{y}" class="lane-line"/>',
                f'<circle cx="30" cy="{y}" r="7" fill="{color}"/>',
                f'<text x="44" y="{y + 5}" class="lane-label">{html_escaped(source)}</text>',
            ]
        )

    for percentage in (0, 0.25, 0.5, 0.75, 1):
        x = plot_left + plot_width * percentage
        svg.extend(
            [
                f'<line x1="{x:.2f}" y1="120" x2="{x:.2f}" y2="{svg_height - 28}" class="grid-line"/>',
                f'<text x="{x:.2f}" y="{svg_height - 8}" text-anchor="middle" class="axis-label">'
                f'{html_escaped(duration(round(total_ms * percentage)))}</text>',
            ]
        )

    for index, value in enumerate(events):
        source = str(value["source"])
        event_name = str(value["event"])
        x = x_for(value["_at_ms"])
        y = lanes[source]
        color = HTML_SOURCE_COLORS.get(source, "#64748b")
        label = f"{source} · {event_name} · {duration(value['_at_ms'] - first_at)}"
        aria_label = html_escaped(label)
        svg.append(
            f'<g class="event-dot" data-event-index="{index}" tabindex="0" role="img" '
            f'aria-label="{aria_label}">'
            f'<circle class="event-hit" cx="{x:.2f}" cy="{y}" r="14"/>'
            f'<circle class="event-point" cx="{x:.2f}" cy="{y}" r="8" fill="{color}">'
            f'<title>{aria_label}</title></circle></g>'
        )
    svg.append('</svg>')

    event_rows: list[str] = []
    previous_at = first_at
    for value in data["events"]:
        at_ms = int(value["at_ms"])
        state_reason = " / ".join(
            str(item) for item in (value.get("state"), value.get("reason")) if item
        )
        color = HTML_SOURCE_COLORS.get(str(value["source"]), "#64748b")
        event_rows.append(
            "<tr>"
            f"<td>{html_escaped(duration(at_ms - first_at))}</td>"
            f"<td>{html_escaped(duration(at_ms - previous_at))}</td>"
            f"<td>{html_escaped(value.get('at', ''))}</td>"
            f'<td><span class="source-dot" style="background:{color}"></span>'
            f"{html_escaped(value['source'])}</td>"
            f"<td><code>{html_escaped(value['event'])}</code></td>"
            f"<td>{html_escaped(state_reason)}</td>"
            "</tr>"
        )
        previous_at = at_ms

    hook_stats: dict[str, dict[str, int]] = {}
    for value in data["events"]:
        if value.get("event") != "hook_observed" or value.get("source") != "bridge":
            continue
        hook_name = str(value.get("hook_event_name") or "unknown")
        stats = hook_stats.setdefault(hook_name, {"observations": 0, "path_captured": 0, "normalized_records": 0})
        stats["observations"] += 1
        if boolean_value(value.get("path_captured")):
            stats["path_captured"] += 1
        normalized_records = nonnegative_count(value.get("normalized_records"))
        if normalized_records is not None:
            stats["normalized_records"] += normalized_records
    hook_rows = "".join(
        f"<tr><td><code>{html_escaped(hook_name)}</code></td>"
        f"<td>{stats['observations']}</td><td>{stats['path_captured']}</td>"
        f"<td>{stats['normalized_records']}</td></tr>"
        for hook_name, stats in sorted(hook_stats.items())
    )
    if not hook_rows:
        hook_rows = '<tr><td colspan="4">No bridge hook observations recorded.</td></tr>'

    milestone_rows = "".join(
        "<tr>"
        f"<td>{html_escaped(milestone['name'])}</td>"
        f"<td>{html_escaped(duration(milestone['elapsed_ms']))}</td>"
        f"<td>{html_escaped(duration(milestone['gap_ms']))}</td>"
        f"<td><code>{html_escaped(milestone['evidence'])}</code></td>"
        "</tr>"
        for milestone in data["milestones"]
    )
    if not milestone_rows:
        milestone_rows = '<tr><td colspan="4">No observation milestones recorded.</td></tr>'

    state_rows = "".join(
        f"<tr><td>{html_escaped(state)}</td><td>{html_escaped(duration(milliseconds))}</td></tr>"
        for state, milliseconds in data["state_durations_ms"].items()
    )
    if not state_rows:
        state_rows = '<tr><td colspan="2">No watcher state observations recorded.</td></tr>'

    question_rows = "".join(
        "<tr>"
        f"<td>{index}</td>"
        f"<td>{html_escaped(question.get('question_source') or 'unknown')}</td>"
        f"<td>{html_escaped(duration(question['detected_to_acknowledged_ms']))}</td>"
        f"<td>{html_escaped(duration(question['detected_to_relayed_ms']))}</td>"
        f"<td>{html_escaped(duration(question['relayed_to_decision_ms']))}</td>"
        f"<td>{html_escaped(duration(question['decision_to_response_ms']))}</td>"
        f"<td>{html_escaped(duration(question['detected_to_resolved_ms']))}</td>"
        "</tr>"
        for index, question in enumerate(data["questions"], 1)
    )
    if not question_rows:
        question_rows = '<tr><td colspan="7">No question events recorded.</td></tr>'

    legend = "".join(
        f'<span class="legend"><i style="background:{HTML_SOURCE_COLORS.get(source, "#64748b")}'
        f'"></i>{html_escaped(source)}</span>'
        for source in sources
    )
    style = """
:root { color-scheme: light dark; --bg:#f8fafc; --fg:#0f172a; --muted:#64748b; --card:#fff; --border:#cbd5e1; --grid:#94a3b8; }
@media (prefers-color-scheme: dark) { :root { --bg:#0f172a; --fg:#e2e8f0; --muted:#94a3b8; --card:#111827; --border:#334155; --grid:#64748b; } }
* { box-sizing:border-box; }
html, body { max-width:100%; overflow-x:hidden; }
body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }
main { width:100%; max-width:1500px; margin:0 auto; padding:28px 22px 48px; }
h1 { margin:0 0 4px; } .sub { color:var(--muted); margin-bottom:22px; }
.cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(170px,1fr)); gap:10px; margin:16px 0 24px; }
.card { min-width:0; background:var(--card); border:1px solid var(--border); border-radius:10px; padding:12px 14px; }
.card strong { display:block; font-size:18px; margin-top:2px; overflow-wrap:anywhere; }
.label,.section-label { color:var(--muted); font-size:11px; letter-spacing:.08em; font-weight:700; }
.graph-wrap { position:relative; width:100%; max-width:100%; overflow:hidden; background:var(--card); border:1px solid var(--border); border-radius:12px; padding:10px; }
.timeline-svg { display:block; width:100%; max-width:100%; height:auto; }
.state-track { fill:var(--grid); opacity:.12; } .state-track-label { fill:var(--muted); font-size:11px; font-weight:700; }
.state-span { opacity:.9; }
.band-label { fill:#0f172a; font-size:12px; font-weight:700; }
.band-empty { fill:var(--muted); font-size:12px; } .lane-label { fill:var(--fg); font-size:13px; font-weight:600; }
.lane-line { stroke:var(--grid); stroke-opacity:.35; } .grid-line { stroke:var(--grid); stroke-opacity:.18; stroke-dasharray:3 5; }
.axis-label { fill:var(--muted); font-size:11px; } .event-dot { cursor:help; outline:none; }
.event-hit { fill:transparent; } .event-point { stroke:var(--card); stroke-width:2; filter:drop-shadow(0 1px 1px #0004); }
.event-dot:focus .event-point, .event-dot:hover .event-point { stroke:#facc15; stroke-width:3; }
.legend-row { display:flex; flex-wrap:wrap; gap:12px; margin:14px 2px 25px; color:var(--muted); }
.legend i,.source-dot { display:inline-block; width:9px; height:9px; border-radius:50%; margin-right:5px; }
.timeline-tooltip { position:absolute; z-index:3; width:max-content; max-width:min(360px,calc(100% - 16px)); padding:10px 12px; border:1px solid var(--border); border-radius:8px; background:var(--card); box-shadow:0 6px 22px #0003; overflow-wrap:anywhere; pointer-events:none; }
.timeline-tooltip[hidden] { display:none; } .tooltip-title { display:block; margin-bottom:6px; } .tooltip-fields { display:grid; grid-template-columns:auto minmax(0,1fr); gap:2px 10px; margin:0; }
.tooltip-fields dt { color:var(--muted); } .tooltip-fields dd { margin:0; word-break:break-word; }
h2 { margin:28px 0 10px; font-size:18px; } .table-scroll { width:100%; max-width:100%; overflow-x:auto; }
table { width:100%; border-collapse:collapse; background:var(--card); border:1px solid var(--border); }
th,td { padding:8px 10px; border-bottom:1px solid var(--border); text-align:left; vertical-align:top; } th { color:var(--muted); font-size:12px; white-space:nowrap; }
tr:last-child td { border-bottom:0; } code { background:#94a3b822; padding:2px 5px; border-radius:4px; } .note { color:var(--muted); margin-top:10px; }
"""
    script = f"""
(() => {{
  const wrapper = document.getElementById("cmux-agent-timeline-graph");
  const tooltip = document.getElementById("cmux-agent-timeline-tooltip");
  const title = tooltip.querySelector(".tooltip-title");
  const fields = tooltip.querySelector(".tooltip-fields");
  const eventData = {html_script_json(data["events"])};
  let activeDot = null;

  function formatDuration(milliseconds) {{
    if (milliseconds < 1000) return `${{milliseconds}}ms`;
    if (milliseconds < 60000) return `${{(milliseconds / 1000).toFixed(3)}}s`;
    const minutes = Math.floor(milliseconds / 60000);
    return `${{minutes}}m ${{((milliseconds % 60000) / 1000).toFixed(3)}}s`;
  }}

  function hideTooltip() {{
    activeDot = null;
    tooltip.hidden = true;
  }}

  function showTooltip(dot, clientX, clientY) {{
    const event = eventData[Number(dot.dataset.eventIndex)];
    if (!event) return;
    activeDot = dot;
    title.textContent = `${{event.source}} · ${{event.event}}`;
    fields.replaceChildren();
    const firstAt = eventData[0].at_ms;
    const values = [
      ["Elapsed", formatDuration(event.at_ms - firstAt)],
      ["Timestamp (UTC)", event.at],
      ["Source", event.source],
      ["Event", event.event],
      ["Cursor hook", event.hook_event_name],
      ["Path captured", event.path_captured],
      ["Normalized records", event.normalized_records],
      ["Failure latched", event.failure_latched],
      ["Classification", event.classification],
      ["Pane state", event.pane_state],
      ["Pane reason", event.pane_reason],
      ["Records", event.records],
      ["Result changed", event.result_changed],
      ["Activity age (s)", event.activity_age_seconds],
      ["State", event.state],
      ["Reason", event.reason],
      ["Status", event.status],
      ["Outcome", event.outcome],
      ["Question source", event.question_source],
      ["Quiet seconds", event.quiet_seconds],
      ["Workspace", event.workspace],
      ["Surface", event.surface],
      ["Cwd", event.cwd],
      ["Event ID", event.event_id],
    ];
    for (const [label, value] of values) {{
      if (value === undefined || value === null || value === "") continue;
      const key = document.createElement("dt");
      key.textContent = label;
      const content = document.createElement("dd");
      content.textContent = String(value);
      fields.append(key, content);
    }}
    tooltip.hidden = false;
    const wrapperRect = wrapper.getBoundingClientRect();
    const dotRect = dot.getBoundingClientRect();
    const anchorX = Number.isFinite(clientX) ? clientX : dotRect.left + dotRect.width / 2;
    const anchorY = Number.isFinite(clientY) ? clientY : dotRect.top + dotRect.height / 2;
    let left = anchorX - wrapperRect.left + 14;
    let top = anchorY - wrapperRect.top - tooltip.offsetHeight - 12;
    if (top < 8) top = anchorY - wrapperRect.top + 14;
    const maxLeft = Math.max(8, wrapper.clientWidth - tooltip.offsetWidth - 8);
    const maxTop = Math.max(8, wrapper.clientHeight - tooltip.offsetHeight - 8);
    left = Math.max(8, Math.min(left, maxLeft));
    top = Math.max(8, Math.min(top, maxTop));
    tooltip.style.left = `${{Math.round(left)}}px`;
    tooltip.style.top = `${{Math.round(top)}}px`;
  }}

  for (const dot of wrapper.querySelectorAll(".event-dot")) {{
    dot.addEventListener("pointerenter", (event) => showTooltip(dot, event.clientX, event.clientY));
    dot.addEventListener("pointermove", (event) => showTooltip(dot, event.clientX, event.clientY));
    dot.addEventListener("pointerleave", hideTooltip);
    dot.addEventListener("focus", () => showTooltip(dot));
    dot.addEventListener("blur", hideTooltip);
    dot.addEventListener("keydown", (event) => {{ if (event.key === "Escape") hideTooltip(); }});
  }}
  window.addEventListener("resize", () => {{ if (activeDot) showTooltip(activeDot); }});
}})();
"""
    html_document = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>cmux-agent timeline graph</title><style>{style}</style></head><body><main>
<h1>cmux-agent timeline graph</h1>
<div class="sub">Metadata-only visualization · job <code>{html_escaped(nonce)}</code></div>
<div class="cards">
<div class="card"><span class="label">Duration</span><strong>{html_escaped(duration(data['total_ms']))}</strong></div>
<div class="card"><span class="label">Events</span><strong>{len(events)}</strong></div>
<div class="card"><span class="label">Started</span><strong>{html_escaped(data['started_at'])}</strong></div>
<div class="card"><span class="label">Finished</span><strong>{html_escaped(data['finished_at'])}</strong></div>
</div>
<div class="graph-wrap" id="cmux-agent-timeline-graph">
<div class="timeline-tooltip" id="cmux-agent-timeline-tooltip" role="tooltip" hidden><strong class="tooltip-title"></strong><dl class="tooltip-fields"></dl></div>
{''.join(svg)}
</div>
<div class="legend-row">{legend}</div>
<h2>State dwell</h2><div class="table-scroll"><table><thead><tr><th>State</th><th>Duration</th></tr></thead><tbody>{state_rows}</tbody></table></div>
<h2>Hook observations</h2><p class="note">These are bridge callback wakeups, not completion evidence. The bridge may capture a transcript path before fresh normalized records exist.</p><div class="table-scroll"><table><thead><tr><th>Cursor hook</th><th>Observations</th><th>Path captured</th><th>Normalized records</th></tr></thead><tbody>{hook_rows}</tbody></table></div>
<h2>Observation milestones</h2><div class="cards"><div class="card"><span class="label">Prompt → first normalized record</span><strong>{html_escaped(duration(data['prompt_to_first_normalized_ms']))}</strong></div></div><div class="table-scroll"><table><thead><tr><th>Milestone</th><th>Elapsed</th><th>Gap from previous milestone</th><th>Evidence</th></tr></thead><tbody>{milestone_rows}</tbody></table></div>
<h2>Question handling</h2><div class="table-scroll"><table><thead><tr><th>#</th><th>Source</th><th>Detected → acknowledged</th><th>Detected → relayed</th><th>Relayed → decision</th><th>Decision → response</th><th>Detected → resolved</th></tr></thead><tbody>{question_rows}</tbody></table></div>
<h2>Event details</h2><div class="table-scroll"><table><thead><tr><th>Elapsed</th><th>Since previous</th><th>Timestamp (UTC)</th><th>Source</th><th>Event</th><th>State / reason</th></tr></thead><tbody>{''.join(event_rows)}</tbody></table></div>
<p class="note">The state band shows watcher-detected states; same-state diagnostic reason changes appear as `observation_changed` events. Supervisor observations remain as `supervisor_observed` events in the supervisor lane and event table. The milestone table separates executor startup from transcript/result observability latency. Hover or keyboard-focus any graph dot for its metadata. The report contains no prompts, transcript contents, or command output.</p>
<script>{script}</script></main></body></html>
"""
    print(html_document, end="")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    record = subparsers.add_parser("record", help="append one timeline event")
    record.add_argument("--timeline", required=True)
    record.add_argument("--event", required=True)
    record.add_argument("--source", required=True, choices=sorted(SOURCES))
    record.add_argument("--job-nonce")
    record.add_argument("--workspace")
    record.add_argument("--surface")
    record.add_argument("--cwd")
    record.add_argument("--at-ms", type=int)
    record.add_argument("--monotonic-ns", type=int)
    record.add_argument("--state")
    record.add_argument("--reason")
    record.add_argument("--question-id")
    record.add_argument("--question-source")
    record.add_argument("--question-kind")
    record.add_argument("--outcome")
    record.add_argument("--status")
    record.add_argument("--quiet-seconds", type=float)
    record.add_argument("--detail", action="append", default=[])
    record.set_defaults(handler=record_event)

    view = subparsers.add_parser("view", help="render a timeline")
    view.add_argument("--timeline", required=True)
    view.add_argument("--format", choices=("markdown", "json", "html"), default="markdown")

    args = parser.parse_args()
    if args.command == "record":
        args.handler(args)
        return
    events, nonce = load_events(timeline_path(args.timeline))
    if args.format == "json":
        print(json.dumps(as_json(events, nonce), indent=2, ensure_ascii=False))
    elif args.format == "html":
        render_html(events, nonce)
    else:
        render_markdown(events, nonce)


if __name__ == "__main__":
    main()
