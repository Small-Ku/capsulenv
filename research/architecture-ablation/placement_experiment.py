/root/.profile: line 11: /workspace/scratch/9406dad8be21/.cargo/env: No such file or directory
#!/usr/bin/env python3
"""Measure logical placement/write amplification for a fixed desired state."""
from __future__ import annotations

import hashlib
import json
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path


PACKAGES = {
    f"pkg{i}": {f"bin/{j}.exe": 4096 + j * 512 for j in range(3)}
    | {"manifest.json": 1024, "install.json": 768}
    for i in range(1, 5)
}


@dataclass
class Metrics:
    portable_bytes: int = 0
    host_bytes: int = 0
    network_bytes: int = 0
    creates: int = 0
    overwrites: int = 0
    state_mutations: int = 0


class Placement:
    def __init__(self, root: Path, blob_area: str, realization_area: str, remote_blobs: bool = False):
        self.root = root
        self.portable = root / "portable"
        self.host = root / "host"
        self.metrics = Metrics()
        self.blob_area = blob_area
        self.realization_area = realization_area
        self.remote_blobs = remote_blobs

    def write(self, relative: str, size: int, area: str, state: bool = False) -> None:
        base = self.portable if area == "portable" else self.host
        path = base / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            self.metrics.overwrites += 1
        else:
            self.metrics.creates += 1
        path.write_bytes(b"x" * size)
        if area == "portable":
            self.metrics.portable_bytes += size
        else:
            self.metrics.host_bytes += size
        self.metrics.state_mutations += int(state)

    def deploy(self) -> None:
        for package, files in PACKAGES.items():
            generation = hashlib.sha256(package.encode()).hexdigest()[:16]
            package_bytes = sum(files.values())
            if self.remote_blobs:
                self.metrics.network_bytes += package_bytes
            else:
                self.write(f"blobs/{package}.blob", package_bytes, self.blob_area)
            for rel, size in files.items():
                self.write(f"realizations/{generation}/{package}/{rel}", size, self.realization_area)
            self.write(f"realizations/{generation}/COMPLETE", 64, self.realization_area, state=True)
            self.write(f"active/{package}.json", 192, "portable", state=True)
        self.write("desired-state.json", 1024, "portable", state=True)

    def result(self) -> dict:
        return self.metrics.__dict__.copy()


def main() -> None:
    specs = [
        ("all-portable", "portable", "portable", False),
        ("host-realization-portable-blobs", "portable", "host", False),
        ("host-realization-host-blobs", "host", "host", False),
        ("host-realization-remote-blobs", "host", "host", True),
    ]
    rows = []
    for name, blob_area, realization_area, remote in specs:
        root = Path(tempfile.mkdtemp(prefix="capsulenv-placement-"))
        try:
            placement = Placement(root, blob_area, realization_area, remote)
            placement.deploy()
            cold = placement.result()
            placement.deploy()
            warm = placement.result()
            rows.append({"variant": name, "cold": cold, "warm_cumulative": warm})
        finally:
            shutil.rmtree(root, ignore_errors=True)
    baseline = rows[0]["cold"]["portable_bytes"]
    for row in rows:
        row["cold_portable_reduction_vs_all_portable_pct"] = round(
            (1 - row["cold"]["portable_bytes"] / baseline) * 100, 3
        )
    print(json.dumps({
        "schema": 1,
        "kind": "placement-logical-write-prototype-measured",
        "workload": {"packages": len(PACKAGES), "files_per_package": len(next(iter(PACKAGES.values())))},
        "rows": rows,
        "limitations": [
            "Bytes are logical application writes, not portable SSD controller writes.",
            "Remote bytes are modeled from immutable blob payloads; no network backend was contacted.",
            "Warm cumulative values include metadata rewrites on the second idempotent deploy.",
        ],
    }, indent=2))


if __name__ == "__main__":
    main()
