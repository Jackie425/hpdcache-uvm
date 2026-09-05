#!/usr/bin/env python3
"""Build and run one HPDcache UVM test."""

from __future__ import annotations

import argparse

from compile import CompileOptions, compile_configs
from sim_common import env_value, project_path, select_dv_configs
from sim_runner import RunSpec, execute_run, validate_run_spec


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build-dir", default=env_value("BUILD_DIR", "build/questa"))
    parser.add_argument(
        "--filelist", default=env_value("FILELIST", "testbench/hpdcache_uvm.f")
    )
    parser.add_argument("--uvm-version", default=env_value("UVM_VERSION", "1.2"))
    parser.add_argument("--config", default="hpdcache_cva6")
    parser.add_argument("--test", default="hpdcache_random_test")
    parser.add_argument("--seed", default="random")
    parser.add_argument("--verbosity", default="UVM_LOW")
    parser.add_argument("--run-name", default="run")
    parser.add_argument(
        "--output-dir",
        help="artifact directory (default: <build-dir>/<config>/<test>)",
    )
    parser.add_argument("--top", default="top")
    parser.add_argument("--optimized-top", default="hpdcache_uvm_opt")
    parser.add_argument("--compile-timeout-seconds", type=float, default=1800.0)
    parser.add_argument("--timeout-seconds", type=float, default=3600.0)
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--extra-arg", action="append", default=[])
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        build_dir = project_path(args.build_dir)
        config_dir = project_path(env_value("CONFIG_DIR", "config"))
        dv_config = select_dv_configs(
            args.config, allow_all=False, config_dir=config_dir
        )[0]
        output_dir = (
            project_path(args.output_dir)
            if args.output_dir
            else build_dir / dv_config / args.test
        )
        run_spec = RunSpec(
            build_dir=build_dir,
            config=dv_config,
            test=args.test,
            seed=args.seed,
            verbosity=args.verbosity,
            output_dir=output_dir,
            uvm_version=args.uvm_version,
            optimized_top=args.optimized_top,
            run_name=args.run_name,
            timeout_seconds=args.timeout_seconds,
            extra_args=tuple(args.extra_arg),
        )
        validate_run_spec(run_spec)
        compile_status = compile_configs(
            dv_config,
            CompileOptions(
                build_dir=build_dir,
                filelist=project_path(args.filelist),
                config_dir=config_dir,
                uvm_version=args.uvm_version,
                top=args.top,
                optimized_top=args.optimized_top,
                timeout_seconds=args.compile_timeout_seconds,
                live=args.live,
            ),
        )
        if compile_status:
            return compile_status

        print(f"Running: config={dv_config} test={args.test} seed={args.seed}")
        outcome = execute_run(run_spec, live=args.live)
    except (OSError, RuntimeError) as error:
        print(f"Test configuration error: {error}")
        return 2

    print(outcome.rendered, end="")
    print(f"Artifacts: {outcome.report_path}  {outcome.json_path}")
    return 0 if outcome.result["status"] == "PASS" else outcome.returncode or 1


if __name__ == "__main__":
    raise SystemExit(main())
