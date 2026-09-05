#!/usr/bin/env python3
"""Reusable execution path for one HPDcache UVM simulation."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
import time
from typing import Any

from generate_report import generate_reports
from sim_common import (
    project_path,
    questa_home,
    questa_tool,
    run_logged,
    simulation_environment,
)


TEST_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_$]*")
RUN_NAME_RE = re.compile(r"[A-Za-z0-9_.-]+")


@dataclass(frozen=True)
class RunSpec:
    build_dir: Path
    config: str
    test: str
    seed: str | int
    verbosity: str
    output_dir: Path
    uvm_version: str = "1.2"
    optimized_top: str = "hpdcache_uvm_opt"
    run_name: str = "run"
    timeout_seconds: float = 3600.0
    extra_args: tuple[str, ...] = ()


@dataclass(frozen=True)
class RunOutcome:
    result: dict[str, Any]
    rendered: str
    returncode: int
    duration_seconds: float
    report_path: Path
    json_path: Path
    console_path: Path


def validate_run_spec(spec: RunSpec) -> None:
    if spec.timeout_seconds <= 0:
        raise RuntimeError("run timeout must be positive")
    if not TEST_RE.fullmatch(spec.test):
        raise RuntimeError(f"invalid UVM test name: {spec.test}")
    if not RUN_NAME_RE.fullmatch(spec.run_name):
        raise RuntimeError(f"invalid run name: {spec.run_name}")


def execute_run(spec: RunSpec, *, live: bool = False) -> RunOutcome:
    """Run one simulation and return its parsed report."""

    validate_run_spec(spec)
    work_dir = spec.build_dir / spec.config / "work"
    if not work_dir.is_dir():
        raise RuntimeError(f"compiled library is missing: {work_dir}")

    env = simulation_environment(spec.uvm_version)
    uvm_lib = questa_home() / f"uvm-{spec.uvm_version}"
    vsim = questa_tool("vsim")
    run_tcl = project_path("scripts/questa/run.tcl")
    if not run_tcl.is_file():
        raise RuntimeError(f"Questa run Tcl was not found: {run_tcl}")

    spec.output_dir.mkdir(parents=True, exist_ok=True)
    log_path = spec.output_dir / f"{spec.run_name}.log"
    console_path = spec.output_dir / f"{spec.run_name}.console.log"
    report_path = spec.output_dir / f"{spec.run_name}.rpt"
    json_path = spec.output_dir / f"{spec.run_name}.json"
    wave_path = spec.output_dir / f"{spec.run_name}.wlf"
    for path in (log_path, console_path, report_path, json_path, wave_path):
        path.unlink(missing_ok=True)
    env.update(
        {
            "HPDCACHE_TCL_WORK_DIR": str(work_dir),
            "HPDCACHE_TCL_UVM_LIB": str(uvm_lib),
            "HPDCACHE_TCL_OPTIMIZED_TOP": spec.optimized_top,
            "HPDCACHE_TCL_TEST": spec.test,
            "HPDCACHE_TCL_VERBOSITY": spec.verbosity,
            "HPDCACHE_TCL_SEED": str(spec.seed),
            "HPDCACHE_TCL_WAVE": str(wave_path),
            "HPDCACHE_TCL_EXTRA_ARG_COUNT": str(len(spec.extra_args)),
        }
    )
    for index, extra_arg in enumerate(spec.extra_args):
        env[f"HPDCACHE_TCL_EXTRA_ARG_{index}"] = extra_arg

    started = time.monotonic()
    returncode = run_logged(
        [vsim, "-c", "-64", "-l", log_path, "-do", run_tcl],
        console_path,
        env=env,
        live=live,
        timeout_seconds=spec.timeout_seconds,
    )
    duration = round(time.monotonic() - started, 3)
    result, rendered = generate_reports(
        log_path,
        report_path,
        json_path,
        simulator_returncode=returncode,
        console_path=console_path,
        dv_config=spec.config,
    )
    return RunOutcome(
        result=result,
        rendered=rendered,
        returncode=returncode,
        duration_seconds=duration,
        report_path=report_path,
        json_path=json_path,
        console_path=console_path,
    )
