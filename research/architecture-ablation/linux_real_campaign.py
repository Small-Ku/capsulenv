#!/usr/bin/env python3
"""Run the architecture workload as real Linux subprocesses.

The output deliberately keeps logical counters (from the workload) separate
from syscall-derived counters (from strace).  It is an experiment harness and
does not change production capsulenv.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path


HERE = Path(__file__).resolve().parent
RUNTIME = HERE / "linux_runtime.py"
STRACE_USABLE: bool | None = None


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * p
    low = int(position)
    high = min(low + 1, len(ordered) - 1)
    fraction = position - low
    return round(ordered[low] + (ordered[high] - ordered[low]) * fraction, 3)


def tree_bytes(path: Path) -> int:
    if not path.exists():
        return 0
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())


def parse_trace(trace_files: list[Path]) -> dict:
    write_bytes = 0
    network_bytes = 0
    file_creates = 0
    file_deletes = 0
    file_renames = 0
    metadata_operations = 0
    fsync_count = 0
    subprocess_count = 0
    exec_count = 0
    process_ids: set[str] = set()
    syscall_counts: dict[str, int] = {}

    successful = r"\s+=\s+(?:[0-9]+|0x[0-9a-f]+)"
    for path in trace_files:
        for line in path.read_text(errors="replace").splitlines():
            pid = line.split(" ", 1)[0]
            if pid.isdigit():
                process_ids.add(pid)
            match = re.search(r"\b([a-zA-Z0-9_]+)\(", line)
            if not match:
                continue
            syscall = match.group(1)
            syscall_counts[syscall] = syscall_counts.get(syscall, 0) + 1
            ok = re.search(successful, line) is not None
            if not ok:
                continue
            if syscall in {"write", "pwrite64", "writev"}:
                result = re.search(r"\)\s+=\s+([0-9]+)", line)
                if result:
                    write_bytes += int(result.group(1))
            if syscall in {"sendto", "sendmsg", "sendmmsg", "recvfrom", "recvmsg", "recvmmsg"}:
                result = re.search(r"\)\s+=\s+([0-9]+)", line)
                if result:
                    network_bytes += int(result.group(1))
            if syscall in {"open", "openat", "openat2", "creat"} and "O_CREAT" in line:
                file_creates += 1
            if syscall in {"unlink", "unlinkat", "rmdir"}:
                file_deletes += 1
            if syscall in {"rename", "renameat", "renameat2"}:
                file_renames += 1
            if syscall in {
                "open", "openat", "openat2", "creat", "close", "mkdir", "mkdirat",
                "stat", "lstat", "fstat", "newfstatat", "access", "faccessat",
                "readlink", "readlinkat", "chmod", "fchmod", "utimensat", "unlink",
                "unlinkat", "rmdir", "rename", "renameat", "renameat2", "link", "symlink",
            }:
                metadata_operations += 1
            if syscall in {"fsync", "fdatasync", "syncfs"}:
                fsync_count += 1
            if syscall in {"clone", "clone3", "fork", "vfork"}:
                subprocess_count += 1
            if syscall == "execve":
                exec_count += 1

    return {
        "write_syscall_bytes": write_bytes,
        "network_syscall_bytes": network_bytes,
        "file_creates_syscall": file_creates,
        "file_deletes_syscall": file_deletes,
        "file_renames_syscall": file_renames,
        "metadata_operations_syscall": metadata_operations,
        "fsync_syscall_count": fsync_count,
        "subprocess_fork_syscalls": subprocess_count,
        "execve_count": exec_count,
        "process_count_observed": len(process_ids),
        "syscall_counts": syscall_counts,
    }


def invoke(root: Path, operation: str, mode: str, workload: str, placement: str, workers: int, trace: bool) -> dict:
    global STRACE_USABLE
    trace_prefix = root / "trace"
    command = [
        sys.executable,
        str(RUNTIME),
        "--root", str(root),
        "--operation", operation,
        "--mode", mode,
        "--workload", workload,
        "--placement", placement,
        "--workers", str(workers),
    ]
    watcher = None
    if trace and shutil.which("inotifywait"):
        watcher = subprocess.Popen(
            ["inotifywait", "-m", "-r", "-q", "-e", "create,delete,moved_from,moved_to,close_write,attrib,modify", str(root)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
    if trace and STRACE_USABLE is not False:
        command = ["strace", "-ff", "-qq", "-o", str(trace_prefix), "-e", "trace=file,process,network,write,fsync,fdatasync"] + command
    started = time.perf_counter()
    process = subprocess.run(command, text=True, capture_output=True)
    elapsed_ms = (time.perf_counter() - started) * 1000
    strace_blocked = process.returncode != 0 and "Operation not permitted" in process.stderr
    if strace_blocked:
        STRACE_USABLE = False
        # The workload itself is still valid; rerun without ptrace and retain
        # the exact capability limitation in the result. This is preferable to
        # turning a telemetry permission failure into a campaign failure.
        process = subprocess.run(command[command.index(sys.executable):], text=True, capture_output=True)
    if watcher is not None:
        watcher.terminate()
        watcher.wait(timeout=5)
        watcher_events = watcher.stdout.read().splitlines() if watcher.stdout else []
    else:
        watcher_events = []
    if process.returncode != 0:
        raise RuntimeError(json.dumps({"command": command, "returncode": process.returncode, "stdout": process.stdout[-2000:], "stderr": process.stderr[-4000:]}))
    lines = [line for line in process.stdout.splitlines() if line.strip()]
    result = json.loads(lines[-1])
    result["wall_ms_parent"] = round(elapsed_ms, 3)
    result["portable_tree_bytes"] = tree_bytes(root / "portable")
    result["host_tree_bytes"] = tree_bytes(root / "host")
    result["inotify"] = {
        "event_count": len(watcher_events),
        "create_events": sum(" CREATE " in line for line in watcher_events),
        "delete_events": sum(" DELETE " in line for line in watcher_events),
        "rename_events": sum(" MOVED_FROM " in line or " MOVED_TO " in line for line in watcher_events),
        "write_events": sum(" CLOSE_WRITE " in line or " MODIFY " in line for line in watcher_events),
    }
    if trace:
        trace_files = sorted(root.glob("trace.*"))
        result["syscall"] = parse_trace(trace_files) if trace_files else {"available": False, "limitation": "ptrace denied: Operation not permitted"}
        if strace_blocked or STRACE_USABLE is False:
            result["syscall"] = {"available": False, "limitation": "ptrace denied: Operation not permitted"}
        for path in trace_files:
            path.unlink(missing_ok=True)
    return result


def run_deploy_series(workload: str, placement: str, mode: str, repeats: int, workers: int) -> dict:
    cold: list[dict] = []
    warm: list[dict] = []
    for _ in range(repeats):
        with tempfile.TemporaryDirectory(prefix="capsulenv-linux-cold-") as name:
            cold.append(invoke(Path(name), "deploy", mode, workload, placement, workers, True))
        with tempfile.TemporaryDirectory(prefix="capsulenv-linux-warm-") as name:
            root = Path(name)
            invoke(root, "deploy", mode, workload, placement, workers, False)
            warm.append(invoke(root, "deploy", mode, workload, placement, workers, True))
    return {"cold": summarize(cold), "warm": summarize(warm), "samples": {"cold": cold, "warm": warm}}


def run_startup_series(workload: str, placement: str, mode: str, repeats: int, workers: int) -> dict:
    results: dict[str, list[dict]] = {"validate": [], "auto": []}
    for _ in range(repeats):
        with tempfile.TemporaryDirectory(prefix="capsulenv-linux-startup-") as name:
            root = Path(name)
            invoke(root, "deploy", mode, workload, placement, workers, False)
            for startup_mode in results:
                results[startup_mode].append(invoke(root, "startup", startup_mode, workload, placement, workers, True))
    return {key: summarize(value) for key, value in results.items()} | {"samples": results}


def run_warm_process_series(workload: str, placement: str, mode: str, repeats: int, workers: int) -> dict:
    values: list[float] = []
    with tempfile.TemporaryDirectory(prefix="capsulenv-linux-server-") as name:
        root = Path(name)
        invoke(root, "deploy", mode, workload, placement, workers, False)
        process = subprocess.Popen(
            [sys.executable, str(RUNTIME), "--server", "--root", str(root)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        )
        try:
            for _ in range(repeats):
                started = time.perf_counter()
                assert process.stdin is not None and process.stdout is not None
                process.stdin.write(json.dumps({"operation": "startup", "mode": "validate", "workload": workload, "placement": placement, "workers": workers}) + "\n")
                process.stdin.flush()
                line = process.stdout.readline()
                if not line:
                    raise RuntimeError("warm server exited before response")
                response = json.loads(line)
                if not response.get("ok"):
                    raise RuntimeError(response)
                values.append((time.perf_counter() - started) * 1000)
        finally:
            if process.stdin:
                process.stdin.close()
            process.wait(timeout=10)
    return {"count": len(values), "p50_ms": percentile(values, 0.50), "p95_ms": percentile(values, 0.95), "samples_ms": [round(value, 3) for value in values]}


def summarize(samples: list[dict]) -> dict:
    walls = [float(sample["wall_ms_parent"]) for sample in samples]
    logical = [int(sample.get("logical_bytes_written", 0)) for sample in samples]
    portable = [int(sample.get("portable_bytes_written", 0)) for sample in samples]
    host = [int(sample.get("host_bytes_written", 0)) for sample in samples]
    network = [int(sample.get("network_bytes", 0)) for sample in samples]
    return {
        "count": len(samples),
        "wall_p50_ms": percentile(walls, 0.50),
        "wall_p95_ms": percentile(walls, 0.95),
        "logical_bytes_written": {"min": min(logical, default=0), "max": max(logical, default=0)},
        "portable_bytes_written": {"min": min(portable, default=0), "max": max(portable, default=0)},
        "host_bytes_written": {"min": min(host, default=0), "max": max(host, default=0)},
        "network_bytes": {"min": min(network, default=0), "max": max(network, default=0)},
        "syscall_write_bytes": {"min": min((s.get("syscall", {}).get("write_syscall_bytes", 0) for s in samples), default=0), "max": max((s.get("syscall", {}).get("write_syscall_bytes", 0) for s in samples), default=0)},
        "file_creates_syscall": {"min": min((s.get("syscall", {}).get("file_creates_syscall", 0) for s in samples), default=0), "max": max((s.get("syscall", {}).get("file_creates_syscall", 0) for s in samples), default=0)},
        "file_deletes_syscall": {"min": min((s.get("syscall", {}).get("file_deletes_syscall", 0) for s in samples), default=0), "max": max((s.get("syscall", {}).get("file_deletes_syscall", 0) for s in samples), default=0)},
        "file_renames_syscall": {"min": min((s.get("syscall", {}).get("file_renames_syscall", 0) for s in samples), default=0), "max": max((s.get("syscall", {}).get("file_renames_syscall", 0) for s in samples), default=0)},
        "metadata_operations_syscall": {"min": min((s.get("syscall", {}).get("metadata_operations_syscall", 0) for s in samples), default=0), "max": max((s.get("syscall", {}).get("metadata_operations_syscall", 0) for s in samples), default=0)},
        "fsync_syscall_count": {"min": min((s.get("syscall", {}).get("fsync_syscall_count", 0) for s in samples), default=0), "max": max((s.get("syscall", {}).get("fsync_syscall_count", 0) for s in samples), default=0)},
        "subprocess_fork_syscalls": {"min": min((s.get("syscall", {}).get("subprocess_fork_syscalls", 0) for s in samples), default=0), "max": max((s.get("syscall", {}).get("subprocess_fork_syscalls", 0) for s in samples), default=0)},
        "execve_count": {"min": min((s.get("syscall", {}).get("execve_count", 0) for s in samples), default=0), "max": max((s.get("syscall", {}).get("execve_count", 0) for s in samples), default=0)},
        "process_count_observed": {"min": min((s.get("syscall", {}).get("process_count_observed", 0) for s in samples), default=0), "max": max((s.get("syscall", {}).get("process_count_observed", 0) for s in samples), default=0)},
        "dag": {key: samples[0].get(key) for key in ("dag_nodes", "dag_edges", "dag_waves", "dag_max_concurrency")} if samples else {},
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--workers", type=int, default=2)
    args = parser.parse_args()
    result: dict = {
        "schema": 1,
        "platform": {"kernel": os.uname().release, "python": sys.version.split()[0], "strace": shutil.which("strace")},
        "workloads": {},
    }
    for workload in ("small", "large"):
        for placement in ("all-portable", "host-realization-portable-blobs", "host-realization-host-blobs", "host-realization-remote-blobs"):
            for mode in ("sequential", "bounded", "ar-dag", "dag"):
                result["workloads"].setdefault(workload, {}).setdefault(placement, {})[mode] = run_deploy_series(workload, placement, mode, args.repeats if workload == "small" else max(3, args.repeats // 2), args.workers)
                print(f"completed deploy workload={workload} placement={placement} mode={mode}", flush=True)
            result["workloads"][workload][placement]["startup"] = run_startup_series(workload, placement, "dag", args.repeats, args.workers)
            print(f"completed startup workload={workload} placement={placement}", flush=True)
            result["workloads"][workload][placement]["warm_process_startup"] = run_warm_process_series(workload, placement, "dag", args.repeats * 2, args.workers)
            print(f"completed warm-process workload={workload} placement={placement}", flush=True)
    Path(args.out).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"out": args.out, "workloads": list(result["workloads"]), "status": "PASS"}))


if __name__ == "__main__":
    main()
