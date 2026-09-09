#!/usr/bin/env python3
"""Build HPDcache UVM configurations with Questa when inputs change."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import fcntl
import hashlib
import json
from pathlib import Path
from typing import Iterable

from sim_common import (
    PROJECT_ROOT,
    env_value,
    print_log_tail,
    project_path,
    questa_home,
    questa_tool,
    run_logged,
    select_dv_configs,
    simulation_environment,
)
from coverage_utils import (
    DEFAULT_COVERAGE_TYPES, DEFAULT_COVERAGE_SCOPE, add_coverage_arguments,
    normalize_coverage_types, validate_coverage_scope,
)


@dataclass(frozen=True)
class CompileOptions:
    build_dir: Path
    filelist: Path
    config_dir: Path
    uvm_version: str
    top: str = "top"
    optimized_top: str = "hpdcache_uvm_opt"
    timeout_seconds: float = 1800.0
    live: bool = False
    coverage: bool = True
    coverage_types: str = DEFAULT_COVERAGE_TYPES
    coverage_scope: str = DEFAULT_COVERAGE_SCOPE


def _source_files(paths: Iterable[Path]) -> list[Path]:
    files: set[Path] = set()
    for path in paths:
        if path.is_file():
            files.add(path.resolve())
        elif path.is_dir():
            files.update(item.resolve() for item in path.rglob("*") if item.is_file())
    return sorted(files)


def _compile_signature(
    options: CompileOptions,
    dv_config: str,
    compile_tcl: Path,
    vsim: Path,
) -> str:
    hpdcache_dir = project_path(env_value("HPDCACHE_DIR", "modules/cv-hpdcache"))
    core_v_verif = project_path(env_value("CORE_V_VERIF", "modules/core-v-verif"))
    cv_dv_uvm = core_v_verif / "lib" / "cv_dv_utils" / "uvm"
    inputs = _source_files(
        (
            options.filelist,
            compile_tcl,
            options.config_dir / f"{dv_config}_config_pkg.sv",
            PROJECT_ROOT / "testbench",
            hpdcache_dir / "rtl",
            cv_dv_uvm / "clock_gen",
            cv_dv_uvm / "reset_gen",
            cv_dv_uvm / "memory_rsp_model",
        )
    )
    digest = hashlib.sha256()
    settings = {
        "config": dv_config,
        "filelist": str(options.filelist),
        "optimized_top": options.optimized_top,
        "top": options.top,
        "uvm_version": options.uvm_version,
        "vsim": str(vsim),
        "coverage_scope": options.coverage_scope,
        "coverage": options.coverage,
        "coverage_types": normalize_coverage_types(options.coverage_types),
    }
    digest.update(json.dumps(settings, sort_keys=True).encode())
    for path in inputs:
        stat = path.stat()
        digest.update(str(path).encode())
        digest.update(f"\0{stat.st_size}\0{stat.st_mtime_ns}\0".encode())
    return digest.hexdigest()


def _manifest_matches(
    path: Path, signature: str, work_dir: Path, optimized_top: str
) -> bool:
    if (
        not work_dir.is_dir()
        or not (work_dir / optimized_top).exists()
        or not path.is_file()
    ):
        return False
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, json.JSONDecodeError):
        return False
    return manifest.get("signature") == signature


def compile_configs(
    selector: str,
    options: CompileOptions,
    *,
    force: bool = False,
) -> int:
    """Ensure selected configurations have current compiled libraries."""

    if options.timeout_seconds <= 0:
        raise RuntimeError("compile timeout must be positive")
    coverage_types = normalize_coverage_types(options.coverage_types)
    validate_coverage_scope(options.coverage_scope)
    dv_configs = select_dv_configs(
        selector, allow_all=True, config_dir=options.config_dir
    )
    env = simulation_environment(options.uvm_version)
    uvm_lib = questa_home() / f"uvm-{options.uvm_version}"
    vsim = questa_tool("vsim")
    compile_tcl = project_path("scripts/questa/compile.tcl")
    if not compile_tcl.is_file():
        raise RuntimeError(f"Questa compile Tcl was not found: {compile_tcl}")

    for dv_config in dv_configs:
        config_build_dir = options.build_dir / dv_config
        config_build_dir.mkdir(parents=True, exist_ok=True)
        work_dir = config_build_dir / "work"
        manifest_path = config_build_dir / "compile.json"
        lock_path = config_build_dir / ".compile.lock"
        with lock_path.open("w", encoding="utf-8") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            signature = _compile_signature(options, dv_config, compile_tcl, vsim)
            if not force and _manifest_matches(
                manifest_path, signature, work_dir, options.optimized_top
            ):
                print(f"Build current: config={dv_config}")
                continue

            manifest_path.unlink(missing_ok=True)
            compile_log = config_build_dir / "compile.log"
            optimize_log = config_build_dir / "vopt.log"
            config_env = env.copy()
            config_env.update(
                {
                    "HPDCACHE_CONFIG_FILE": str(
                        options.config_dir / f"{dv_config}_config_pkg.sv"
                    ),
                    "HPDCACHE_TCL_WORK_DIR": str(work_dir),
                    "HPDCACHE_TCL_UVM_LIB": str(uvm_lib),
                    "HPDCACHE_TCL_FILELIST": str(options.filelist),
                    "HPDCACHE_TCL_CONFIG_PKG": f"{dv_config}_config_pkg",
                    "HPDCACHE_TCL_TOP": options.top,
                    "HPDCACHE_TCL_OPTIMIZED_TOP": options.optimized_top,
                    "HPDCACHE_TCL_COMPILE_LOG": str(compile_log),
                    "HPDCACHE_TCL_OPTIMIZE_LOG": str(optimize_log),
                    "HPDCACHE_TCL_COVERAGE": "1" if options.coverage else "0",
                    "HPDCACHE_TCL_COVERAGE_TYPES": coverage_types,
                    "HPDCACHE_TCL_COVERAGE_SCOPE": options.coverage_scope,
                }
            )
            print(f"Building: config={dv_config}")
            console_log = config_build_dir / "build.console.log"
            session_log = config_build_dir / "build.log"
            status = run_logged(
                [vsim, "-c", "-64", "-l", session_log, "-do", compile_tcl],
                console_log,
                env=config_env,
                live=options.live,
                timeout_seconds=options.timeout_seconds,
            )
            if status:
                print(f"Build failed; see {console_log}")
                print_log_tail(console_log)
                return status
            manifest_path.write_text(
                json.dumps(
                    {
                        "config": dv_config,
                        "signature": signature,
                        "coverage": options.coverage,
                        "coverage_types": coverage_types,
                        "coverage_scope": options.coverage_scope,
                    },
                    indent=2,
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
            print(f"Build complete: {config_build_dir}")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", default=env_value("BUILD_DIR", "build/questa"))
    parser.add_argument(
        "--filelist", default=env_value("FILELIST", "testbench/hpdcache_uvm.f")
    )
    parser.add_argument("--uvm-version", default=env_value("UVM_VERSION", "1.2"))
    parser.add_argument("--config", default="hpdcache_cva6")
    parser.add_argument("--top", default="top")
    parser.add_argument("--optimized-top", default="hpdcache_uvm_opt")
    parser.add_argument("--timeout-seconds", type=float, default=1800.0)
    parser.add_argument("--live", action="store_true")
    add_coverage_arguments(parser)
    parser.add_argument("--force", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    options = CompileOptions(
        build_dir=project_path(args.build_dir),
        filelist=project_path(args.filelist),
        config_dir=project_path(env_value("CONFIG_DIR", "config")),
        uvm_version=args.uvm_version,
        top=args.top,
        optimized_top=args.optimized_top,
        timeout_seconds=args.timeout_seconds,
        live=args.live,
        coverage=args.coverage,
        coverage_types=args.coverage_types,
        coverage_scope=args.coverage_scope,
    )
    try:
        return compile_configs(args.config, options, force=args.force)
    except (OSError, RuntimeError, ValueError) as error:
        print(f"Build configuration error: {error}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
