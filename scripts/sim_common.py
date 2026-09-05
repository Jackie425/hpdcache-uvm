#!/usr/bin/env python3
"""Shared process and path helpers for the Questa wrappers."""

from __future__ import annotations

import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
from typing import Sequence


PROJECT_ROOT = Path(__file__).resolve().parents[1]
CONFIG_FILE_SUFFIX = "_config_pkg.sv"
CONFIG_NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def env_value(name: str, default: str) -> str:
    return os.environ.get(name, default)


def project_path(value: str) -> Path:
    path = Path(value)
    if not path.is_absolute():
        path = PROJECT_ROOT / path
    return path.resolve()


def available_dv_configs(config_dir: str | Path | None = None) -> tuple[str, ...]:
    directory = project_path(
        str(config_dir) if config_dir is not None else env_value("CONFIG_DIR", "config")
    )
    if not directory.is_dir():
        raise RuntimeError(f"DV configuration directory was not found: {directory}")
    configs = tuple(
        sorted(
            path.name[: -len(CONFIG_FILE_SUFFIX)]
            for path in directory.glob(f"*{CONFIG_FILE_SUFFIX}")
            if CONFIG_NAME_RE.fullmatch(path.name[: -len(CONFIG_FILE_SUFFIX)])
        )
    )
    if not configs:
        raise RuntimeError(f"no DV configurations were found in {directory}")
    return configs


def select_dv_configs(
    selector: str,
    *,
    allow_all: bool,
    config_dir: str | Path | None = None,
) -> tuple[str, ...]:
    available = available_dv_configs(config_dir)
    if selector == "all":
        if allow_all:
            return available
        raise RuntimeError("configuration 'all' is not supported for a single test")
    if selector not in available:
        supported = ", ".join(available)
        raise RuntimeError(
            f"unsupported DV configuration {selector!r}; supported: {supported}, all"
        )
    return (selector,)


def questa_home() -> Path:
    value = os.environ.get("QUESTA_HOME")
    if not value:
        raise RuntimeError("QUESTA_HOME is not set")
    path = Path(value).expanduser().resolve()
    if not path.is_dir():
        raise RuntimeError(f"QUESTA_HOME is not a directory: {path}")
    return path


def questa_tool(name: str) -> Path:
    tool = questa_home() / "bin" / name
    if not tool.is_file():
        raise RuntimeError(f"Questa tool was not found: {tool}")
    return tool


def simulation_environment(uvm_version: str) -> dict[str, str]:
    env = os.environ.copy()
    home = questa_home()
    env.setdefault("HPDCACHE_DIR", env_value("HPDCACHE_DIR", "modules/cv-hpdcache"))
    env.setdefault("CORE_V_VERIF", env_value("CORE_V_VERIF", "modules/core-v-verif"))
    env.setdefault("CONFIG_DIR", env_value("CONFIG_DIR", "config"))
    env.setdefault("UVM_SRC", str(home / "verilog_src" / f"uvm-{uvm_version}" / "src"))
    return env


def run_logged(
    command: Sequence[str | Path],
    console_log: Path,
    *,
    env: dict[str, str],
    live: bool = False,
    timeout_seconds: float | None = None,
) -> int:
    """Run a command, always capturing its merged stdout/stderr."""

    console_log.parent.mkdir(parents=True, exist_ok=True)
    normalized = [str(part) for part in command]
    with console_log.open("w", encoding="utf-8", errors="replace") as output:
        process = subprocess.Popen(
            normalized,
            cwd=PROJECT_ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            start_new_session=True,
        )
        assert process.stdout is not None

        reader_errors: list[str] = []

        def copy_output() -> None:
            try:
                for line in process.stdout:
                    output.write(line)
                    if live:
                        sys.stdout.write(line)
                        sys.stdout.flush()
            except (OSError, ValueError) as error:
                reader_errors.append(str(error))

        def terminate_process() -> None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                return
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()

        reader = threading.Thread(target=copy_output, daemon=True)
        reader.start()
        timed_out = False
        try:
            returncode = process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            terminate_process()
            returncode = 124
        except BaseException:
            terminate_process()
            process.stdout.close()
            reader.join(timeout=5)
            raise

        reader.join(timeout=5)
        if reader.is_alive():
            process.stdout.close()
            reader.join(timeout=5)
            reader_errors.append("output reader did not stop")
        if timed_out:
            message = f"Process timed out after {timeout_seconds:g} seconds\n"
            output.write(message)
            if live:
                sys.stdout.write(message)
                sys.stdout.flush()
        if reader_errors:
            message = f"Output capture failed: {reader_errors[0]}\n"
            output.write(message)
            if live:
                sys.stdout.write(message)
                sys.stdout.flush()
            return returncode or 1
        return returncode


def print_log_tail(path: Path, line_count: int = 30) -> None:
    if not path.is_file():
        return
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    for line in lines[-line_count:]:
        print(line)
