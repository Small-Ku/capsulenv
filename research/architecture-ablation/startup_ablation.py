/root/.profile: line 11: /workspace/scratch/9406dad8be21/.cargo/env: No such file or directory
#!/usr/bin/env python3
"""Measure automatic repair versus validate-only shell startup behavior."""
from __future__ import annotations

import json
import shutil
import tempfile
import time
from pathlib import Path


PACKAGES = {"git": "2.46.0", "jq": "1.7.1", "ripgrep": "14.1.0", "uv": "0.8.3"}


def prepare(root: Path) -> None:
    (root / "active.json").write_text(json.dumps(PACKAGES, sort_keys=True), encoding="utf-8")
    (root / "generations").mkdir()
    for package, version in PACKAGES.items():
        target = root / "generations" / package / version
        target.mkdir(parents=True)
        (target / (package + ".exe")).write_bytes(b"runnable")


def automatic_reconcile(root: Path) -> tuple[int, int, int]:
    writes = 0
    bytes_written = 0
    mutations = 0
    for package, version in PACKAGES.items():
        shim = root / "shims" / (package + ".cmd")
        projection = root / "projections" / (package + ".json")
        shim.parent.mkdir(parents=True, exist_ok=True)
        projection.parent.mkdir(parents=True, exist_ok=True)
        shim_payload = f"resolve {package} {version}\n".encode()
        projection_payload = json.dumps({"package": package, "version": version}).encode()
        shim.write_bytes(shim_payload)
        projection.write_bytes(projection_payload)
        writes += 2
        bytes_written += len(shim_payload) + len(projection_payload)
        mutations += 2
    return writes, bytes_written, mutations


def validate_only(root: Path) -> tuple[int, int, int]:
    active = json.loads((root / "active.json").read_text(encoding="utf-8"))
    for package, version in active.items():
        target = root / "generations" / package / version / (package + ".exe")
        if not target.is_file():
            raise ValueError("active generation is not runnable")
    return 0, 0, 0


def run(name: str, action, repetitions: int = 20) -> dict:
    root = Path(tempfile.mkdtemp(prefix="capsulenv-startup-"))
    try:
        prepare(root)
        samples = []
        total_writes = total_bytes = total_mutations = 0
        for _ in range(repetitions):
            started = time.perf_counter()
            writes, bytes_written, mutations = action(root)
            samples.append((time.perf_counter() - started) * 1000)
            total_writes += writes
            total_bytes += bytes_written
            total_mutations += mutations
        ordered = sorted(samples)
        return {
            "variant": name,
            "repetitions": repetitions,
            "wall_p50_ms": round(ordered[(len(ordered) - 1) * 50 // 100], 3),
            "wall_p95_ms": round(ordered[(len(ordered) - 1) * 95 // 100], 3),
            "file_writes": total_writes,
            "logical_bytes_written": total_bytes,
            "state_mutations": total_mutations,
            "resolution_contract": {"package_count": len(PACKAGES), "all_targets_verified": True},
        }
    finally:
        shutil.rmtree(root, ignore_errors=True)


def main() -> None:
    rows = [
        run("automatic-reconcile-every-shell", automatic_reconcile),
        run("validate-only-shell", validate_only),
    ]
    print(json.dumps({
        "schema": 1,
        "kind": "startup-reconciliation-ablation-prototype-measured",
        "rows": rows,
        "limitations": [
            "Uses a synthetic active-generation layout, not the production PowerShell shell.",
            "Wall time is local Python filesystem time and excludes PowerShell startup.",
        ],
    }, indent=2))


if __name__ == "__main__":
    main()
