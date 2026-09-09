#!/usr/bin/env python3
"""Generate concise text and JSON reports from an HPDcache UVM transcript."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import re
from typing import Any

from sim_common import project_path


REPORT_RE = re.compile(
    r"\bUVM_INFO\b.*\[(HPDCACHE_RPT_[A-Z0-9_]+)\]\s*(.*)$"
)
CHECK_FAILURE_RE = re.compile(
    r"\bUVM_(?:ERROR|FATAL)\b.*\[(HPDCACHE_CHK_[A-Z0-9_]+)\]"
)
FIELD_RE = re.compile(r"([a-z][a-z0-9_]*)=([^\s]+)")
SEVERITY_RE = re.compile(
    r"^\s*#?\s*UVM_(INFO|WARNING|ERROR|FATAL)\s*:\s*([0-9]+)\s*$",
    re.MULTILINE,
)
SEED_RE = re.compile(r"^\s*#?\s*Sv_Seed\s*=\s*([0-9]+)\s*$", re.MULTILINE)
SEED_ARGUMENT_RE = re.compile(r"(?:^|\s)-sv_seed\s+([0-9]+)(?:\s|$)")
STARTUP_FAILURE_RE = re.compile(
    r"(^|[\s#*])(Error|Fatal):|Error loading design|Trouble making server|"
    r"license checkout failed|Unable to checkout.*license|Process timed out after",
    re.IGNORECASE | re.MULTILINE,
)

REPORT_SCHEMA = 1


@dataclass(frozen=True)
class CheckSpec:
    key: str
    label: str
    check_id: str
    report_id: str | None = None
    required_fields: tuple[str, ...] = ()
    activity_fields: tuple[str, ...] = ()
    expected_fields: tuple[tuple[str, int], ...] = ()


CHECK_SPECS = (
    CheckSpec("cri", "CRI protocol", "HPDCACHE_CHK_CRI"),
    CheckSpec(
        "cmi",
        "CMI write assembly",
        "HPDCACHE_CHK_CMI",
        "HPDCACHE_RPT_CHECK_CMI",
        (
            "writes_assembled",
            "pending_write_addr",
            "pending_write_data",
            "pending_read_beats",
            "pending_write_responses",
        ),
        ("writes_assembled",),
        (
            ("pending_write_addr", 0),
            ("pending_write_data", 0),
            ("pending_read_beats", 0),
            ("pending_write_responses", 0),
        ),
    ),
    CheckSpec(
        "predictor",
        "Predictor",
        "HPDCACHE_CHK_PREDICTOR",
        "HPDCACHE_RPT_CHECK_PREDICTOR",
        (
            "requests",
            "predictions",
            "abort_predictions",
            "no_rsp",
            "pending",
            "atomic_updates",
            "atomic_predictions",
            "pending_atomics",
        ),
        ("predictions",),
        (("pending", 0), ("pending_atomics", 0)),
    ),
    CheckSpec(
        "cacheable",
        "Cacheable responses",
        "HPDCACHE_CHK_CACHEABLE",
        "HPDCACHE_RPT_CHECK_CACHEABLE",
        ("actual", "expected", "checked", "skipped"),
        ("checked",),
    ),
    CheckSpec(
        "uc_amo_forwarding",
        "UC/AMO forwarding requests/responses",
        "HPDCACHE_CHK_UC_AMO_FORWARDING",
        "HPDCACHE_RPT_CHECK_UC_AMO_FORWARDING",
        (
            "cri_requests",
            "cri_responses",
            "cmi_requests",
            "cmi_responses",
            "cri_responses_checked",
            "requests_checked",
            "responses_checked",
            "no_rsp",
        ),
        ("requests_checked", "responses_checked"),
    ),
    CheckSpec(
        "abort",
        "Abort handling",
        "HPDCACHE_CHK_ABORT",
        "HPDCACHE_RPT_CHECK_ABORT",
        ("checked",),
        ("checked",),
    ),
    CheckSpec(
        "order",
        "Response ordering",
        "HPDCACHE_CHK_ORDER",
        "HPDCACHE_RPT_CHECK_ORDER",
        ("checked", "mismatches"),
        ("checked",),
        (("mismatches", 0),),
    ),
    CheckSpec("tid", "TID bookkeeping", "HPDCACHE_CHK_TID"),
    CheckSpec("sequence", "Sequence response matching", "HPDCACHE_CHK_SEQUENCE"),
    CheckSpec(
        "drain",
        "Environment drain",
        "HPDCACHE_CHK_DRAIN",
        "HPDCACHE_RPT_DRAIN",
        (
            "drained",
            "scoreboard_idle",
            "cmi_idle",
            "driver_outstanding",
            "sequencer_outstanding",
        ),
        ("drained",),
        (
            ("drained", 1),
            ("scoreboard_idle", 1),
            ("cmi_idle", 1),
            ("driver_outstanding", 0),
            ("sequencer_outstanding", 0),
        ),
    ),
)

SINGLE_RECORD_FIELDS = {
    "HPDCACHE_RPT_META": ("schema",),
    "HPDCACHE_RPT_CONFIG": (
        "active_requesters",
        "total_requesters",
        "has_prefetcher",
    ),
    "HPDCACHE_RPT_TRAFFIC_CMI": ("requests", "responses"),
    "HPDCACHE_RPT_CHECK_ATOMIC": ("checked", "local_sc_failures"),
    "HPDCACHE_RPT_END": ("complete",),
    **{
        spec.report_id: spec.required_fields
        for spec in CHECK_SPECS
        if spec.report_id is not None
    },
}
CRI_FIELDS = ("requester", "active", "requests", "vipt", "aborts", "responses")
def parse_fields(payload: str) -> dict[str, str]:
    return {match.group(1): match.group(2) for match in FIELD_RE.finditer(payload)}


def parse_log(text: str) -> dict[str, Any]:
    records: dict[str, list[dict[str, str]]] = {}
    check_failures: dict[str, int] = {}
    for line in text.splitlines():
        match = REPORT_RE.search(line)
        if match:
            records.setdefault(match.group(1), []).append(parse_fields(match.group(2)))
        failure_match = CHECK_FAILURE_RE.search(line)
        if failure_match:
            message_id = failure_match.group(1)
            check_failures[message_id] = check_failures.get(message_id, 0) + 1

    severities = {name: 0 for name in ("INFO", "WARNING", "ERROR", "FATAL")}
    severity_matches = list(SEVERITY_RE.finditer(text))
    for match in severity_matches:
        severities[match.group(1)] = int(match.group(2))

    seed_match = SEED_RE.search(text) or SEED_ARGUMENT_RE.search(text)
    return {
        "records": records,
        "check_failures": check_failures,
        "severities": severities,
        "has_uvm_summary": bool(severity_matches),
        "seed": int(seed_match.group(1)) if seed_match else None,
        "startup_failure": bool(STARTUP_FAILURE_RE.search(text)),
    }


def first_record(parsed: dict[str, Any], message_id: str) -> dict[str, str]:
    values = parsed["records"].get(message_id, [])
    return values[0] if values else {}


def integer(
    record: dict[str, str],
    field: str,
    incomplete: list[str],
    context: str,
) -> int:
    value = record.get(field)
    if value is None:
        incomplete.append(f"{context} is missing {field}")
        return 0
    try:
        return int(value, 0)
    except ValueError:
        incomplete.append(f"{context}.{field} is not an integer: {value}")
        return 0


def number(record: dict[str, Any], field: str) -> int:
    value = record.get(field, 0)
    if type(value) is int:
        return value
    try:
        return int(value, 0)
    except (TypeError, ValueError):
        return 0


def _analyze_stimulus(
    records: list[dict[str, str]],
    completed: int,
    incomplete: list[str],
    failures: list[str],
    reset_test: bool = False,
) -> dict[str, Any]:
    sequences = [dict(record) for record in records]
    planned_values: list[int] = []
    all_planned = bool(sequences)
    for index, record in enumerate(sequences):
        context = f"HPDCACHE_RPT_STIMULUS[{index}]"
        if not record.get("vseq") and not record.get("sequence"):
            incomplete.append(f"{context} is missing vseq or sequence")
        for field in ("workers", "items_per_worker", "planned"):
            if field in record:
                value = integer(record, field, incomplete, context)
                if field == "planned":
                    planned_values.append(value)
            elif field == "planned":
                all_planned = False

    planned = sum(planned_values) if all_planned else None
    if planned is not None:
        if reset_test and completed > planned:
            failures.append(
                f"reset stimulus observed {completed} items above {planned} planned items"
            )
        elif not reset_test and completed != planned:
            failures.append(
                f"stimulus completed {completed} of {planned} planned items"
            )
    summary = dict(sequences[0]) if len(sequences) == 1 else {}
    summary.update(
        {"sequences": sequences, "completed": completed, "planned": planned}
    )
    return summary


def _analyze_reset(
    parsed: dict[str, Any],
    reset_test: bool,
    incomplete: list[str],
) -> dict[str, Any]:
    records = parsed["records"].get("HPDCACHE_RPT_RESET", [])
    if not reset_test:
        return {}
    if len(records) != 1:
        incomplete.append(
            f"expected one HPDCACHE_RPT_RESET record, found {len(records)}"
        )
        return dict(records[0]) if records else {}

    record = dict(records[0])
    accounting_records = parsed["records"].get("HPDCACHE_RPT_RESET_ACCOUNTING", [])
    if reset_test and len(accounting_records) != 1:
        incomplete.append(
            "expected one HPDCACHE_RPT_RESET_ACCOUNTING record, "
            f"found {len(accounting_records)}"
        )
    if accounting_records:
        accounting = dict(accounting_records[0])
        record["accounting"] = accounting
    return record


def _check_activity(
    spec: CheckSpec,
    record: dict[str, Any],
    cri_records: list[dict[str, str]],
) -> int | str:
    if spec.key == "cri":
        return sum(
            number(item, "requests") + number(item, "responses")
            for item in cri_records
        )
    if not spec.activity_fields:
        return "monitored"
    values = [str(record.get(field, "?")) for field in spec.activity_fields]
    return "/".join(values)


def _analyze_checks(
    parsed: dict[str, Any],
    cri_records: list[dict[str, str]],
    incomplete: list[str],
    failures: list[str],
) -> dict[str, dict[str, Any]]:
    checks: dict[str, dict[str, Any]] = {}
    for spec in CHECK_SPECS:
        record = (
            dict(first_record(parsed, spec.report_id))
            if spec.report_id is not None
            else {}
        )
        state_failed = False
        for field, expected in spec.expected_fields:
            if record:
                actual = integer(record, field, incomplete, spec.report_id or spec.key)
                if actual != expected:
                    state_failed = True
                    failures.append(f"{spec.report_id}.{field}={actual}")
        error_count = parsed["check_failures"].get(spec.check_id, 0)
        record.update(
            {
                "status": "UNKNOWN"
                if spec.report_id is not None and not record
                else "FAIL"
                if state_failed or error_count
                else "PASS",
                "activity": _check_activity(spec, record, cri_records),
                "failures": error_count,
            }
        )
        checks[spec.key] = record

    for message_id, count in parsed["check_failures"].items():
        if count:
            failures.append(f"{message_id}={count}")
    return checks


def analyze(
    parsed: dict[str, Any], simulator_returncode: int | None = None
) -> dict[str, Any]:
    incomplete: list[str] = []
    failures: list[str] = []
    records = parsed["records"]

    for message_id in SINGLE_RECORD_FIELDS:
        count = len(records.get(message_id, []))
        if count != 1:
            incomplete.append(f"expected one {message_id} record, found {count}")
    cri_records = records.get("HPDCACHE_RPT_TRAFFIC_CRI", [])
    if not cri_records:
        incomplete.append("no HPDCACHE_RPT_TRAFFIC_CRI records were found")
    if not parsed["has_uvm_summary"]:
        incomplete.append("UVM report summary is missing")
    if parsed["startup_failure"]:
        incomplete.append("simulator startup failed")
    if simulator_returncode:
        failures.append(f"simulator exited with status {simulator_returncode}")

    for message_id, fields in SINGLE_RECORD_FIELDS.items():
        records_for_id = records.get(message_id, [])[:1]
        for record in records_for_id:
            for field in fields:
                integer(record, field, incomplete, message_id)
    for record in cri_records:
        for field in CRI_FIELDS:
            integer(record, field, incomplete, "HPDCACHE_RPT_TRAFFIC_CRI")

    meta = first_record(parsed, "HPDCACHE_RPT_META")
    if meta:
        schema = integer(meta, "schema", incomplete, "HPDCACHE_RPT_META")
        if schema != REPORT_SCHEMA:
            incomplete.append(f"unsupported report schema: {schema}")
        if not meta.get("test"):
            incomplete.append("HPDCACHE_RPT_META is missing test")

    config = first_record(parsed, "HPDCACHE_RPT_CONFIG")
    if config:
        expected_total = integer(
            config, "total_requesters", incomplete, "HPDCACHE_RPT_CONFIG"
        )
        expected_active = integer(
            config, "active_requesters", incomplete, "HPDCACHE_RPT_CONFIG"
        )
        requester_ids = [
            integer(record, "requester", incomplete, "HPDCACHE_RPT_TRAFFIC_CRI")
            for record in cri_records
        ]
        observed_active = sum(
            integer(record, "active", incomplete, "HPDCACHE_RPT_TRAFFIC_CRI")
            for record in cri_records
        )
        if len(cri_records) != expected_total:
            incomplete.append(
                f"expected {expected_total} CRI traffic records, "
                f"found {len(cri_records)}"
            )
        if len(set(requester_ids)) != len(requester_ids):
            incomplete.append("duplicate CRI requester records were found")
        if sorted(requester_ids) != list(range(expected_total)):
            incomplete.append(
                "CRI requester records do not cover IDs 0 through "
                f"{expected_total - 1}"
            )
        if observed_active != expected_active:
            incomplete.append(
                f"expected {expected_active} active requesters, found {observed_active}"
            )

    completed = sum(
        integer(record, "requests", incomplete, "HPDCACHE_RPT_TRAFFIC_CRI")
        for record in cri_records
    )
    reset_test = meta.get("test") == "hpdcache_on_the_fly_reset_test"
    stimulus = _analyze_stimulus(
        records.get("HPDCACHE_RPT_STIMULUS", []),
        completed,
        incomplete,
        failures,
        reset_test,
    )
    reset = _analyze_reset(parsed, reset_test, incomplete)
    checks = _analyze_checks(
        parsed, cri_records, incomplete, failures
    )

    end = first_record(parsed, "HPDCACHE_RPT_END")
    if end and integer(end, "complete", incomplete, "HPDCACHE_RPT_END") != 1:
        incomplete.append("HPDCACHE_RPT_END.complete is not 1")
    for severity in ("ERROR", "FATAL"):
        count = parsed["severities"][severity]
        if count:
            failures.append(f"UVM_{severity}={count}")

    incomplete = list(dict.fromkeys(incomplete))
    failures = list(dict.fromkeys(failures))
    status = "INCOMPLETE" if incomplete else "FAIL" if failures else "PASS"
    return {
        "schema": REPORT_SCHEMA,
        "status": status,
        "seed": parsed["seed"],
        "configuration": "unknown",
        "metadata": meta,
        "config": config,
        "stimulus": stimulus,
        "traffic": {
            "cri": cri_records,
            "cmi": first_record(parsed, "HPDCACHE_RPT_TRAFFIC_CMI"),
        },
        "checks": checks,
        "drain": first_record(parsed, "HPDCACHE_RPT_DRAIN"),
        "reset": reset,
        "uvm": parsed["severities"],
        "execution": {"simulator_returncode": simulator_returncode},
        "incomplete_reasons": incomplete,
        "failure_reasons": failures,
    }


def render_text(result: dict[str, Any]) -> str:
    meta = result["metadata"]
    config = result["config"]
    stimulus = result["stimulus"]
    cri = result["traffic"]["cri"]
    cmi = result["traffic"]["cmi"]
    checks = result["checks"]
    drain = result["drain"]
    reset = result.get("reset", {})
    uvm = result["uvm"]
    total_cri = {
        field: sum(number(record, field) for record in cri)
        for field in ("requests", "responses", "vipt", "aborts")
    }
    seed = result["seed"] if result["seed"] is not None else "unknown"
    prefetcher = {"0": "no", "1": "yes"}.get(
        config.get("has_prefetcher"), "unknown"
    )
    lines = [
        "=" * 72,
        "HPDcache Test Report",
        "=" * 72,
        f"Result              : {result['status']}",
        f"DV configuration    : {result.get('configuration', 'unknown')}",
        f"Test                : {meta.get('test', 'unknown')}",
        f"Seed                : {seed}",
        "",
        "Configuration",
        "-------------",
        f"Active requesters   : {config.get('active_requesters', '?')}",
        f"Prefetcher present  : {prefetcher}",
        "",
        "Stimulus",
        "--------",
    ]
    sequences = stimulus.get("sequences", [])
    if not sequences:
        lines.append("Sequences           : not reported by this test")
    for index, record in enumerate(sequences, start=1):
        sequence = record.get("vseq", record.get("sequence", "unknown"))
        details = [
            value
            for value in (
                record.get("worker"),
                record.get("api_sequence"),
            )
            if value
        ]
        suffix = f" -> {' -> '.join(details)}" if details else ""
        label = "Sequence" if len(sequences) == 1 else f"Sequence {index}"
        lines.append(f"{label:<20}: {sequence}{suffix}")
    planned = stimulus.get("planned")
    lines.extend(
        [
            f"Observed / planned  : {stimulus.get('completed', '?')} / "
            f"{planned if planned is not None else 'not reported'}",
        ]
    )
    if reset:
        accounting = reset.get("accounting", {})
        lines.extend(
            [
                "",
                "Reset",
                "-----",
                f"Resets              : {reset.get('resets', '?')}",
                f"Signal driven       : {reset.get('signal_driven', '?')}",
                f"Phase jump          : {reset.get('phase_jump', '?')}",
                f"Recovery complete   : {reset.get('recovery_complete', '?')}",
                f"Accounting          : {accounting.get('observed', '?')} observed + "
                f"{accounting.get('legal_cancellations', '?')} cancelled / "
                f"{accounting.get('planned', '?')} planned "
                f"(balanced={accounting.get('balanced', '?')})",
            ]
        )
    lines.extend(
        [
            "",
            "Traffic",
            "-------",
            f"CRI requests        : {total_cri['requests']}",
            f"CRI responses       : {total_cri['responses']}",
            f"VIPT requests       : {total_cri['vipt']}",
            f"Aborted requests    : {total_cri['aborts']}",
            f"No-response requests: {checks['predictor'].get('no_rsp', '?')}",
            f"CMI requests        : {cmi.get('requests', '?')}",
            f"CMI responses       : {cmi.get('responses', '?')}",
            "",
            "CRI by requester",
            "----------------",
            "  ID  Mode       Requests  Responses  VIPT  Aborts",
        ]
    )
    for record in sorted(cri, key=lambda item: number(item, "requester")):
        mode = "active" if record.get("active") == "1" else "passive"
        lines.append(
            f"  {record.get('requester', '?'):>2}  {mode:<7} "
            f"{record.get('requests', '?'):>10} {record.get('responses', '?'):>10} "
            f"{record.get('vipt', '?'):>5} {record.get('aborts', '?'):>7}"
        )

    lines.extend(
        [
            "",
            "Checks",
            "------",
            f"  {'Check':<32} {'Status':<8} {'Activity':>18} {'Errors':>8}",
        ]
    )
    for spec in CHECK_SPECS:
        check = checks[spec.key]
        lines.append(
            f"  {spec.label:<32} {check['status']:<8} "
            f"{str(check['activity']):>18} {str(check['failures']):>8}"
        )
    lines.extend(
        [
            "",
            "Completion",
            "----------",
            f"Environment drained : {'yes' if drain.get('drained') == '1' else 'no'}",
            f"Driver outstanding  : {drain.get('driver_outstanding', '?')}",
            f"TID outstanding     : {drain.get('sequencer_outstanding', '?')}",
            "",
            "Diagnostics",
            "-----------",
            f"UVM warnings        : {uvm['WARNING']}",
            f"UVM errors          : {uvm['ERROR']}",
            f"UVM fatals          : {uvm['FATAL']}",
        ]
    )
    coverage = result.get("coverage")
    if coverage:
        lines.extend(["", "Coverage", "--------", f"Collection/report   : {coverage['status']}"])
        if coverage.get("enabled"):
            lines.append(f"Code types / scope  : {coverage['types']} / {coverage['scope']}")
            for key in ("ucdb", "report", "html"):
                if coverage.get(key):
                    lines.append(f"{key.upper():<20}: {coverage[key]}")
    issues = result["incomplete_reasons"] + result["failure_reasons"]
    if issues:
        lines.extend(["", "Issues", "------"])
        lines.extend(f"  - {issue}" for issue in issues)
    return "\n".join(lines) + "\n"


def generate_reports(
    log_path: Path,
    text_path: Path,
    json_path: Path,
    simulator_returncode: int | None = None,
    console_path: Path | None = None,
    dv_config: str | None = None,
    coverage: dict[str, Any] | None = None,
) -> tuple[dict[str, Any], str]:
    text = (
        log_path.read_text(encoding="utf-8", errors="replace")
        if log_path.is_file()
        else ""
    )
    parsed = parse_log(text)
    if console_path is not None and console_path.is_file():
        console_text = console_path.read_text(encoding="utf-8", errors="replace")
        parsed["startup_failure"] |= bool(STARTUP_FAILURE_RE.search(console_text))
    result = analyze(parsed, simulator_returncode)
    if dv_config is not None:
        result["configuration"] = dv_config
    if coverage is not None:
        result["coverage"] = coverage
        if coverage["enabled"] and coverage["status"] != "PASS":
            result["incomplete_reasons"].extend(coverage["issues"])
            if result["status"] == "PASS":
                result["status"] = "INCOMPLETE"
    rendered = render_text(result)
    text_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    text_path.write_text(rendered, encoding="utf-8")
    json_path.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return result, rendered


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True)
    parser.add_argument("--text-output")
    parser.add_argument("--json-output")
    parser.add_argument("--console")
    parser.add_argument("--simulator-returncode", type=int)
    parser.add_argument("--config")
    return parser.parse_args()


def _previous_execution(json_path: Path) -> tuple[int | None, str | None]:
    if not json_path.is_file():
        return None, None
    try:
        previous = json.loads(json_path.read_text(encoding="utf-8"))
    except (OSError, ValueError, json.JSONDecodeError):
        return None, None
    execution = previous.get("execution", {})
    returncode = (
        execution.get("simulator_returncode")
        if isinstance(execution, dict)
        else None
    )
    config = previous.get("configuration")
    return (
        returncode if type(returncode) is int else None,
        config if isinstance(config, str) else None,
    )


def main() -> int:
    args = parse_args()
    log_path = project_path(args.log)
    stem = log_path.with_suffix("")
    text_path = (
        project_path(args.text_output)
        if args.text_output
        else stem.with_suffix(".rpt")
    )
    json_path = (
        project_path(args.json_output)
        if args.json_output
        else stem.with_suffix(".json")
    )
    previous_returncode, previous_config = _previous_execution(json_path)
    previous_coverage = None
    try:
        previous_coverage = json.loads(json_path.read_text(encoding="utf-8")).get("coverage")
    except (OSError, ValueError, AttributeError):
        pass
    console_path = (
        project_path(args.console)
        if args.console
        else stem.with_suffix(".console.log")
    )
    result, rendered = generate_reports(
        log_path,
        text_path,
        json_path,
        simulator_returncode=(
            args.simulator_returncode
            if args.simulator_returncode is not None
            else previous_returncode
        ),
        console_path=console_path,
        dv_config=args.config or previous_config,
        coverage=previous_coverage,
    )
    print(rendered, end="")
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
