#!/usr/bin/env python3
"""Build and run a YAML-defined HPDcache regression."""

from __future__ import annotations

import argparse
from concurrent.futures import Future, ThreadPoolExecutor, as_completed
from dataclasses import dataclass
import json
from pathlib import Path
import re
import secrets
import shutil
import time
from typing import Any

import yaml

from compile import CompileOptions, compile_configs
from sim_common import PROJECT_ROOT, env_value, project_path, select_dv_configs
from sim_runner import RunSpec, execute_run


NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*")
TEST_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_$]*")
VERBOSITIES = {
    "UVM_NONE",
    "UVM_LOW",
    "UVM_MEDIUM",
    "UVM_HIGH",
    "UVM_FULL",
    "UVM_DEBUG",
}
TOP_LEVEL_KEYS = {"schema", "name", "defaults", "tests"}
DEFAULT_KEYS = {"verbosity"}
TEST_KEYS = {"test", "runs", "verbosity"}


class TestlistError(ValueError):
    """A regression testlist is malformed."""


@dataclass(frozen=True)
class RegressionTest:
    test: str
    runs: int
    verbosity: str


@dataclass(frozen=True)
class RegressionJob:
    test: str
    seed: int
    verbosity: str


@dataclass(frozen=True)
class RegressionTestlist:
    name: str
    tests: tuple[RegressionTest, ...]


def new_seed(used: set[int]) -> int:
    seed = secrets.randbelow(0xFFFFFFFF) + 1
    while seed in used:
        seed = secrets.randbelow(0xFFFFFFFF) + 1
    return seed


def _mapping(value: object, context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise TestlistError(f"{context} must be a mapping")
    if not all(isinstance(key, str) for key in value):
        raise TestlistError(f"{context} keys must be strings")
    return value


def _check_keys(mapping: dict[str, Any], allowed: set[str], context: str) -> None:
    unknown = sorted(set(mapping) - allowed)
    if unknown:
        raise TestlistError(f"{context} has unknown key(s): {', '.join(unknown)}")


def _verbosity(value: object, context: str) -> str:
    if not isinstance(value, str) or value not in VERBOSITIES:
        choices = ", ".join(sorted(VERBOSITIES))
        raise TestlistError(f"{context} must be one of: {choices}")
    return value


def load_testlist(path: Path) -> RegressionTestlist:
    try:
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise TestlistError(f"cannot read {path}: {error}") from error
    except yaml.YAMLError as error:
        raise TestlistError(f"invalid YAML in {path}: {error}") from error

    root = _mapping(document, "testlist")
    _check_keys(root, TOP_LEVEL_KEYS, "testlist")
    if type(root.get("schema")) is not int or root["schema"] != 1:
        raise TestlistError("testlist.schema must be integer 1")

    name = root.get("name")
    if not isinstance(name, str) or not NAME_RE.fullmatch(name):
        raise TestlistError(
            "testlist.name must be one filesystem-safe component beginning "
            "with a letter or digit"
        )

    defaults = _mapping(root.get("defaults", {}), "testlist.defaults")
    _check_keys(defaults, DEFAULT_KEYS, "testlist.defaults")
    default_verbosity = _verbosity(
        defaults.get("verbosity", "UVM_LOW"), "testlist.defaults.verbosity"
    )

    entries = root.get("tests")
    if not isinstance(entries, list) or not entries:
        raise TestlistError("testlist.tests must be a non-empty list")

    tests: list[RegressionTest] = []
    seen_tests: set[str] = set()
    for entry_index, value in enumerate(entries):
        context = f"testlist.tests[{entry_index}]"
        entry = _mapping(value, context)
        _check_keys(entry, TEST_KEYS, context)
        test = entry.get("test")
        if not isinstance(test, str) or not TEST_RE.fullmatch(test):
            raise TestlistError(f"{context}.test is not a valid UVM test name")
        if test in seen_tests:
            raise TestlistError(f"duplicate test entry: {test}")
        seen_tests.add(test)
        runs = entry.get("runs", 1)
        if type(runs) is not int or runs < 1:
            raise TestlistError(f"{context}.runs must be a positive integer")
        verbosity = _verbosity(
            entry.get("verbosity", default_verbosity), f"{context}.verbosity"
        )
        tests.append(RegressionTest(test, runs, verbosity))
    return RegressionTestlist(name=name, tests=tuple(tests))


def _relative(path: Path, base: Path) -> str:
    try:
        return str(path.relative_to(base))
    except ValueError:
        return str(path)


def _integer(value: object) -> int | None:
    if type(value) is int:
        return value
    if isinstance(value, str):
        try:
            return int(value, 0)
        except ValueError:
            pass
    return None


def job_output_dir(
    regression_dir: Path, dv_config: str, job: RegressionJob
) -> Path:
    return regression_dir / dv_config / job.test / str(job.seed)


def schedule_jobs(
    testlist: RegressionTestlist, dv_configs: tuple[str, ...]
) -> list[tuple[int, str, RegressionJob]]:
    scheduled: list[tuple[int, str, RegressionJob]] = []
    used_by_test: dict[str, set[int]] = {}
    for dv_config in dv_configs:
        for test in testlist.tests:
            used = used_by_test.setdefault(test.test, set())
            for _ in range(test.runs):
                seed = new_seed(used)
                used.add(seed)
                job = RegressionJob(test.test, seed, test.verbosity)
                scheduled.append((len(scheduled), dv_config, job))
    return scheduled


def _sequence_names(stimulus: object) -> list[str]:
    if not isinstance(stimulus, dict):
        return []
    records = stimulus.get("sequences", [])
    if not isinstance(records, list):
        return []
    names: list[str] = []
    for record in records:
        if not isinstance(record, dict):
            continue
        name = record.get("vseq", record.get("sequence"))
        if isinstance(name, str):
            names.append(name)
    return names


def _check_summary(checks: object) -> dict[str, Any]:
    if not isinstance(checks, dict):
        return {"passed": 0, "total": 0, "failed": []}
    statuses = {
        name: value.get("status")
        for name, value in checks.items()
        if isinstance(name, str) and isinstance(value, dict)
    }
    return {
        "passed": sum(status == "PASS" for status in statuses.values()),
        "total": len(statuses),
        "failed": sorted(name for name, status in statuses.items() if status != "PASS"),
    }


def run_job(
    job: RegressionJob,
    *,
    result_index: int,
    build_dir: Path,
    regression_dir: Path,
    dv_config: str,
    uvm_version: str,
    optimized_top: str,
    timeout_seconds: float,
) -> dict[str, Any]:
    output_dir = job_output_dir(regression_dir, dv_config, job)
    outcome = execute_run(
        RunSpec(
            build_dir=build_dir,
            config=dv_config,
            test=job.test,
            seed=job.seed,
            verbosity=job.verbosity,
            output_dir=output_dir,
            uvm_version=uvm_version,
            optimized_top=optimized_top,
            timeout_seconds=timeout_seconds,
        )
    )
    report = outcome.result
    raw_status = report.get("status")
    status = (
        raw_status
        if raw_status in {"PASS", "FAIL", "INCOMPLETE"}
        else "INCOMPLETE"
    )
    issues: list[str] = []
    if raw_status not in {"PASS", "FAIL", "INCOMPLETE"}:
        issues.append(f"run result has invalid status: {raw_status!r}")
    for key in ("incomplete_reasons", "failure_reasons"):
        report_issues = report.get(key, [])
        if isinstance(report_issues, list):
            issues.extend(str(issue) for issue in report_issues)
        else:
            issues.append(f"run result {key} is not a list")

    stimulus = report.get("stimulus", {})
    completed_requests = (
        _integer(stimulus.get("completed")) if isinstance(stimulus, dict) else None
    )
    uvm = report.get("uvm", {})
    uvm_counts = {
        severity.lower(): _integer(uvm.get(severity)) if isinstance(uvm, dict) else None
        for severity in ("WARNING", "ERROR", "FATAL")
    }
    return {
        "index": result_index,
        "config": dv_config,
        "test": job.test,
        "seed": job.seed,
        "verbosity": job.verbosity,
        "status": status,
        "duration_seconds": outcome.duration_seconds,
        "returncode": outcome.returncode,
        "completed_requests": completed_requests,
        "sequences": _sequence_names(stimulus),
        "checks": _check_summary(report.get("checks")),
        "uvm": uvm_counts,
        "issues": issues,
        "artifacts": {
            "directory": _relative(output_dir, regression_dir),
            "report": _relative(outcome.report_path, regression_dir),
            "json": _relative(outcome.json_path, regression_dir),
        },
    }


def summarize(
    testlist: RegressionTestlist,
    testlist_path: Path,
    dv_configs: tuple[str, ...],
    results: list[dict[str, Any]],
    duration: float,
    requested_jobs: int,
) -> dict[str, Any]:
    counts = {
        status.lower(): sum(result["status"] == status for result in results)
        for status in ("PASS", "FAIL", "INCOMPLETE")
    }
    status = (
        "INCOMPLETE"
        if counts["incomplete"]
        else "FAIL"
        if counts["fail"]
        else "PASS"
    )
    requests = [result["completed_requests"] for result in results]
    return {
        "schema": 1,
        "status": status,
        "regression": {
            "name": testlist.name,
            "testlist": _relative(testlist_path, PROJECT_ROOT),
            "configs": list(dv_configs),
            "duration_seconds": round(duration, 3),
            "concurrency": requested_jobs,
        },
        "summary": {
            "total": len(results),
            **counts,
            "completed_requests": sum(
                value for value in requests if isinstance(value, int)
            ),
        },
        "runs": results,
    }


def _sequence_cell(result: dict[str, Any]) -> str:
    sequences = result["sequences"]
    if not sequences:
        return "-"
    if len(sequences) == 1:
        return sequences[0]
    return f"{sequences[0]} (+{len(sequences) - 1})"


def render_summary(summary: dict[str, Any]) -> str:
    regression = summary["regression"]
    counts = summary["summary"]
    results = summary["runs"]
    test_width = max([len("Test"), *(len(result["test"]) for result in results)])
    config_width = max(
        [len("Configuration"), *(len(result["config"]) for result in results)]
    )
    sequence_width = max(
        [len("Sequence"), *(len(_sequence_cell(result)) for result in results)]
    )
    lines = [
        "=" * 96,
        "HPDcache Regression Report",
        "=" * 96,
        f"Result              : {summary['status']}",
        f"Regression          : {regression['name']} ({regression['testlist']})",
        f"DV configurations   : {', '.join(regression['configs'])}",
        f"Runs                : {counts['total']} total, {counts['pass']} passed, "
        f"{counts['fail']} failed, {counts['incomplete']} incomplete",
        f"Completed requests  : {counts['completed_requests']}",
        f"Elapsed             : {regression['duration_seconds']:.3f} s",
        "",
        "Runs",
        "----",
        f"  {'Status':<10} {'Configuration':<{config_width}} "
        f"{'Test':<{test_width}} {'Sequence':<{sequence_width}} "
        f"{'Seed':>10} {'Requests':>10} {'Checks':>7} "
        f"{'Warnings':>8} {'Errors':>6} {'Fatals':>6} {'Time':>9}",
    ]
    for result in results:
        uvm = result["uvm"]
        requests = result["completed_requests"]
        checks = result["checks"]
        check_cell = f"{checks['passed']}/{checks['total']}"
        lines.append(
            f"  {result['status']:<10} {result['config']:<{config_width}} "
            f"{result['test']:<{test_width}} "
            f"{_sequence_cell(result):<{sequence_width}} "
            f"{result['seed']:>10} "
            f"{str(requests if requests is not None else '?'):>10} "
            f"{check_cell:>7} "
            f"{str(uvm['warning'] if uvm['warning'] is not None else '?'):>8} "
            f"{str(uvm['error'] if uvm['error'] is not None else '?'):>6} "
            f"{str(uvm['fatal'] if uvm['fatal'] is not None else '?'):>6} "
            f"{result['duration_seconds']:>7.3f} s"
        )

    failed = [result for result in results if result["status"] != "PASS"]
    if failed:
        lines.extend(["", "Issues", "------"])
        for result in failed:
            identity = (
                f"{result['config']} {result['test']} seed={result['seed']}"
            )
            if result["issues"]:
                lines.extend(f"  {identity}: {issue}" for issue in result["issues"])
            else:
                lines.append(f"  {identity}: no diagnostic was reported")
    return "\n".join(lines) + "\n"


def incomplete_result(
    job: RegressionJob,
    result_index: int,
    regression_dir: Path,
    dv_config: str,
    issue: str,
) -> dict[str, Any]:
    output_dir = job_output_dir(regression_dir, dv_config, job)
    return {
        "index": result_index,
        "config": dv_config,
        "test": job.test,
        "seed": job.seed,
        "verbosity": job.verbosity,
        "status": "INCOMPLETE",
        "duration_seconds": 0.0,
        "returncode": None,
        "completed_requests": None,
        "sequences": [],
        "checks": {"passed": 0, "total": 0, "failed": []},
        "uvm": {"warning": None, "error": None, "fatal": None},
        "issues": [issue],
        "artifacts": {
            "directory": _relative(output_dir, regression_dir),
            "report": _relative(output_dir / "run.rpt", regression_dir),
            "json": _relative(output_dir / "run.json", regression_dir),
        },
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--testlist", required=True, help="YAML regression testlist")
    parser.add_argument("--config", default="hpdcache_cva6")
    parser.add_argument("--jobs", type=int, default=4, help="maximum concurrent tests")
    parser.add_argument("--build-dir", default=env_value("BUILD_DIR", "build/questa"))
    parser.add_argument(
        "--filelist", default=env_value("FILELIST", "testbench/hpdcache_uvm.f")
    )
    parser.add_argument("--uvm-version", default=env_value("UVM_VERSION", "1.2"))
    parser.add_argument("--top", default="top")
    parser.add_argument("--optimized-top", default="hpdcache_uvm_opt")
    parser.add_argument("--compile-timeout-seconds", type=float, default=1800.0)
    parser.add_argument("--timeout-seconds", type=float, default=3600.0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.jobs < 1:
        print("Regression configuration error: --jobs must be at least 1")
        return 2
    if args.timeout_seconds <= 0:
        print("Regression configuration error: --timeout-seconds must be positive")
        return 2

    testlist_path = project_path(args.testlist)
    build_dir = project_path(args.build_dir)
    config_dir = project_path(env_value("CONFIG_DIR", "config"))
    try:
        testlist = load_testlist(testlist_path)
        dv_configs = select_dv_configs(
            args.config, allow_all=True, config_dir=config_dir
        )
        compile_status = compile_configs(
            args.config,
            CompileOptions(
                build_dir=build_dir,
                filelist=project_path(args.filelist),
                config_dir=config_dir,
                uvm_version=args.uvm_version,
                top=args.top,
                optimized_top=args.optimized_top,
                timeout_seconds=args.compile_timeout_seconds,
            ),
        )
        if compile_status:
            return compile_status
    except (OSError, TestlistError, RuntimeError) as error:
        print(f"Regression configuration error: {error}")
        return 2

    regression_dir = build_dir / "regression" / testlist.name
    try:
        if regression_dir.exists():
            shutil.rmtree(regression_dir)
        regression_dir.mkdir(parents=True)
    except OSError as error:
        print(f"Unable to initialize regression directory {regression_dir}: {error}")
        return 2

    scheduled = schedule_jobs(testlist, dv_configs)
    worker_count = min(args.jobs, len(scheduled))
    print(
        f"Regression: name={testlist.name} configs={','.join(dv_configs)} "
        f"runs={len(scheduled)} jobs={worker_count}"
    )
    started = time.monotonic()
    results: list[dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=worker_count) as executor:
        futures: dict[
            Future[dict[str, Any]], tuple[int, str, RegressionJob]
        ] = {
            executor.submit(
                run_job,
                job,
                result_index=index,
                build_dir=build_dir,
                regression_dir=regression_dir,
                dv_config=dv_config,
                uvm_version=args.uvm_version,
                optimized_top=args.optimized_top,
                timeout_seconds=args.timeout_seconds,
            ): (index, dv_config, job)
            for index, dv_config, job in scheduled
        }
        for completed_count, future in enumerate(as_completed(futures), start=1):
            index, dv_config, job = futures[future]
            try:
                result = future.result()
            except Exception as error:
                result = incomplete_result(
                    job,
                    index,
                    regression_dir,
                    dv_config,
                    f"regression worker failed: {error}",
                )
            results.append(result)
            print(
                f"[{completed_count}/{len(scheduled)}] {result['status']:<10} "
                f"config={result['config']} test={result['test']} "
                f"seed={result['seed']} "
                f"time={result['duration_seconds']:.3f}s"
            )

    results.sort(key=lambda result: result["index"])
    for result in results:
        del result["index"]
    summary = summarize(
        testlist,
        testlist_path,
        dv_configs,
        results,
        time.monotonic() - started,
        worker_count,
    )
    rendered = render_summary(summary)
    report_path = regression_dir / "regression.rpt"
    json_path = regression_dir / "regression.json"
    report_path.write_text(rendered, encoding="utf-8")
    json_path.write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(rendered, end="")
    print(f"Artifacts: {report_path}  {json_path}")
    return 0 if summary["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
