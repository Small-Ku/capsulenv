#!/usr/bin/env python3
"""Measure projection reconciliation versus a stable active-generation resolver."""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
RUNTIME = HERE / "linux_runtime.py"


def pct(values: list[float], p: float) -> float:
    values = sorted(values)
    pos = (len(values) - 1) * p
    lo = int(pos)
    hi = min(lo + 1, len(values) - 1)
    return round(values[lo] + (values[hi] - values[lo]) * (pos - lo), 3)


def invoke(root: Path, mode: str, workload: str) -> dict:
    command = [sys.executable, str(RUNTIME), "--root", str(root), "--operation", "startup", "--mode", mode, "--workload", workload, "--placement", "all-portable", "--workers", "2"]
    started = time.perf_counter()
    result = subprocess.run(command, capture_output=True, text=True, check=True)
    return {"wall_ms_parent": round((time.perf_counter() - started) * 1000, 3), "result": json.loads(result.stdout)}


def write_resolver(path: Path) -> None:
    path.write_text(
        """import json, pathlib, sys\nroot = pathlib.Path(sys.argv[1])\npackage = sys.argv[2]\nactive = json.loads((root/'portable/capsule-home/state/active.json').read_text())\ngeneration = active[package]\ntarget = root/'portable/realizations'/generation/package\nif not target.is_dir(): raise SystemExit(2)\nprint(target)\n""",
        encoding="utf-8",
    )


def write_shell_resolver(path: Path) -> None:
    path.write_text(
        r"""#!/bin/sh
set -eu
root=$1
package=$2
active=$root/portable/capsule-home/state/active.json
generation=$(grep -o "\"$package\": \"[0-9a-f]*\"" "$active" | cut -d '"' -f 4)
[ -n "$generation" ]
test -d "$root/portable/realizations/$generation/$package"
""",
        encoding="utf-8",
    )
    path.chmod(0o755)


def run(workload: str, repeats: int) -> dict:
    with tempfile.TemporaryDirectory(prefix="capsulenv-projection-real-") as name:
        root = Path(name)
        subprocess.run([sys.executable, str(RUNTIME), "--root", str(root), "--operation", "deploy", "--mode", "dag", "--workload", workload, "--placement", "all-portable", "--workers", "2"], check=True, capture_output=True, text=True)
        resolver = root / "resolver.py"
        write_resolver(resolver)
        shell_resolver = root / "resolver.sh"
        write_shell_resolver(shell_resolver)
        auto = [invoke(root, "auto", workload) for _ in range(repeats)]
        validate = [invoke(root, "validate", workload) for _ in range(repeats)]
        resolver_times: list[float] = []
        shell_resolver_times: list[float] = []
        direct_times: list[float] = []
        package = "pkg1" if workload == "small" else "base"
        for _ in range(repeats * 5):
            started = time.perf_counter()
            subprocess.run([sys.executable, str(resolver), str(root), package], capture_output=True, text=True, check=True)
            resolver_times.append((time.perf_counter() - started) * 1000)
            started = time.perf_counter()
            subprocess.run([str(shell_resolver), str(root), package], capture_output=True, text=True, check=True)
            shell_resolver_times.append((time.perf_counter() - started) * 1000)
            started = time.perf_counter()
            subprocess.run(["/bin/true"], check=True)
            direct_times.append((time.perf_counter() - started) * 1000)
        return {
            "workload": workload,
            "repeats": repeats,
            "startup_auto": {"p50_ms": pct([x["wall_ms_parent"] for x in auto], .5), "p95_ms": pct([x["wall_ms_parent"] for x in auto], .95), "logical_bytes": [x["result"]["logical_bytes_written"] for x in auto]},
            "startup_validate": {"p50_ms": pct([x["wall_ms_parent"] for x in validate], .5), "p95_ms": pct([x["wall_ms_parent"] for x in validate], .95), "logical_bytes": [x["result"]["logical_bytes_written"] for x in validate]},
            "stable_resolver": {"p50_ms": pct(resolver_times, .5), "p95_ms": pct(resolver_times, .95)},
            "stable_shell_resolver": {"p50_ms": pct(shell_resolver_times, .5), "p95_ms": pct(shell_resolver_times, .95)},
            "direct_process_baseline": {"p50_ms": pct(direct_times, .5), "p95_ms": pct(direct_times, .95)},
            "resolver_overhead_over_direct_p50_ms": round(pct(resolver_times, .5) - pct(direct_times, .5), 3),
            "shell_resolver_overhead_over_direct_p50_ms": round(pct(shell_resolver_times, .5) - pct(direct_times, .5), 3),
        }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--repeats", type=int, default=7)
    args = parser.parse_args()
    result = {"schema": 1, "evidence": "linux-real-process", "rows": [run(workload, args.repeats) for workload in ("small", "large")]}
    Path(args.out).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
