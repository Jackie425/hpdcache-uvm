"""Questa coverage configuration, artifact validation, and reporting."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
from typing import Any, Iterable

from sim_common import env_value, project_path, questa_tool, run_logged


_COVERAGE_TYPE_ORDER = "sbceftx"
# Extended toggle includes ordinary toggle; Questa treats t and x as alternatives.
DEFAULT_COVERAGE_TYPES = "sbcefx"
# A trailing dot tells Questa to recurse through every child instance.
DEFAULT_COVERAGE_SCOPE = "/top/dut."


def parse_bool(value: str) -> bool:
    normalized = value.strip().lower()
    if normalized in {"1", "yes", "true", "on"}:
        return True
    if normalized in {"0", "no", "false", "off"}:
        return False
    raise ValueError(f"invalid COVERAGE boolean: {value!r}")


def normalize_coverage_types(value: str) -> str:
    types = value.strip().lower()
    if not types or set(types) - set(_COVERAGE_TYPE_ORDER):
        raise ValueError("coverage types must contain only s/b/c/e/f/t/x")
    if "x" in types:
        types = types.replace("t", "")
    return "".join(char for char in _COVERAGE_TYPE_ORDER if char in types)


def validate_coverage_scope(scope: str) -> str:
    if not scope.startswith("/") or any(c in scope for c in "+*?[]\n\r"):
        raise ValueError("coverage scope must be an absolute instance path without wildcards or '+'")
    return scope


def add_coverage_arguments(parser: argparse.ArgumentParser) -> None:
    try:
        enabled = parse_bool(env_value("COVERAGE", "1"))
    except ValueError as error:
        parser.error(str(error))
    parser.add_argument(
        "--coverage", action=argparse.BooleanOptionalAction, default=enabled,
        help="collect coverage (default: enabled; --no-coverage disables it)",
    )
    parser.add_argument(
        "--coverage-types", default=env_value("COVERAGE_TYPES", DEFAULT_COVERAGE_TYPES),
        help="code categories: s/b/c/e/f/t/x (default: sbcefx; x includes t)",
    )
    parser.add_argument(
        "--coverage-scope", default=env_value("COVERAGE_SCOPE", DEFAULT_COVERAGE_SCOPE),
        help="RTL instance subtree to instrument and save (default: /top/dut.)",
    )


def nonempty_file(path: Path) -> bool:
    return path.is_file() and path.stat().st_size > 0


def coverage_record(enabled: bool, types: str, scope: str) -> dict[str, Any]:
    return {
        "enabled": enabled, "types": types, "scope": scope,
        "status": "INCOMPLETE" if enabled else "DISABLED",
        "ucdb": None, "report": None, "html": None, "issues": [],
    }


def generate_coverage_report(
    *, ucdb: Path, html_dir: Path, text_report: Path, log_path: Path,
    console_path: Path, env: dict[str, str], types: str, timeout_seconds: float,
) -> None:
    """Render one UCDB; a tool failure or missing report is an error."""
    if not nonempty_file(ucdb):
        raise RuntimeError(f"coverage UCDB is missing or empty: {ucdb}")
    report_env = env.copy()
    report_env.update({
        "HPDCACHE_TCL_COVERAGE_TYPES": types,
        "HPDCACHE_TCL_COVERAGE_HTML": str(html_dir),
        "HPDCACHE_TCL_COVERAGE_REPORT": str(text_report),
    })
    status = run_logged(
        [questa_tool("vsim"), "-c", "-64", "-viewcov", ucdb, "-l", log_path,
         "-do", project_path("scripts/questa/coverage_report.tcl")],
        console_path, env=report_env, timeout_seconds=timeout_seconds,
    )
    if status:
        raise RuntimeError(f"coverage report failed ({status}); see {console_path}")
    if not nonempty_file(text_report) or not nonempty_file(html_dir / "index.html"):
        raise RuntimeError(f"coverage report output is missing; see {console_path}")


def merge_coverage_databases(
    ucdbs: Iterable[Path], *, output: Path, log_path: Path,
    env: dict[str, str], timeout_seconds: float,
) -> None:
    """Merge the explicit run list, never stale databases found by globbing."""
    inputs = list(ucdbs)
    if not inputs or any(not nonempty_file(path) for path in inputs):
        raise RuntimeError("coverage merge requires nonempty per-run UCDB files")
    # A response file avoids command-line size limits on large regressions.
    input_list = output.with_suffix(".inputs")
    if any('"' in str(path) or "\n" in str(path) for path in inputs):
        raise RuntimeError("coverage input paths cannot contain quotes or newlines")
    input_list.write_text("".join(f"{path}\n" for path in inputs), encoding="utf-8")
    status = run_logged(
        [questa_tool("vcover"), "merge", "-64", "-out", output, "-inputs", input_list],
        log_path, env=env, timeout_seconds=timeout_seconds,
    )
    if status or not nonempty_file(output):
        raise RuntimeError(f"coverage merge failed ({status}); see {log_path}")


def generate_coverage_summary(
    *, ucdb: Path, summary_path: Path, log_path: Path,
    env: dict[str, str], timeout_seconds: float,
) -> dict[str, Any]:
    """Generate and parse Questa's per-instance coverage summary."""
    if not nonempty_file(ucdb):
        raise RuntimeError(f"coverage UCDB is missing or empty: {ucdb}")
    status = run_logged(
        [
            questa_tool("vcover"), "report", "-codeAll", "-assert",
            "-output", summary_path, ucdb,
        ],
        log_path, env=env, timeout_seconds=timeout_seconds,
    )
    if status or not nonempty_file(summary_path):
        raise RuntimeError(f"coverage summary failed ({status}); see {log_path}")
    text = summary_path.read_text(encoding="utf-8", errors="replace")
    metrics: dict[str, dict[str, int | float]] = {}
    metric_re = re.compile(
        r"^\s*(Assertions|Branches|Conditions|Expressions|Statements|Toggles|"
        r"FSM States|FSM Transitions|FSMs?)\s+"
        r"(\d+)\s+(\d+)\s+(\d+)\s+([0-9.]+)%\s*$",
        re.MULTILINE,
    )
    for match in metric_re.finditer(text):
        name = {
            "Assertions": "assertion",
            "Branches": "branch", "Conditions": "condition",
            "Expressions": "expression", "Statements": "statement",
            "Toggles": "toggle", "FSM States": "fsm_states",
            "FSM Transitions": "fsm_transitions", "FSM": "fsm", "FSMs": "fsm",
        }[match.group(1)]
        current = metrics.setdefault(name, {"bins": 0, "hits": 0, "misses": 0})
        current["bins"] += int(match.group(2))
        current["hits"] += int(match.group(3))
        current["misses"] += int(match.group(4))
    for metric in metrics.values():
        metric["coverage"] = round(100.0 * metric["hits"] / metric["bins"], 2) if metric["bins"] else 0.0
    total_match = re.search(
        r"Total Coverage By Instance \(filtered view\):\s*([0-9.]+)%", text
    )
    if not total_match:
        raise RuntimeError(f"coverage summary has no total percentage: {summary_path}")
    return {"total": float(total_match.group(1)), "metrics": metrics}
