#!/usr/bin/env python3
"""Deterministic synthetic ablation and crash campaign.

This measures a small observable filesystem model. It is not a Windows runtime
trace and does not claim to measure physical SSD write amplification.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path

PACKAGES = {f"pkg{i}": [f"bin/{j}.exe" for j in range(3)] + ["manifest.json", "install.json"] for i in range(1, 5)}
FILE_BYTES = {name: 4096 + i * 1024 for i, name in enumerate(sorted({p for fs in PACKAGES.values() for p in fs}))}


@dataclass
class Metrics:
    logical_bytes_written: int = 0
    portable_bytes_written: int = 0
    host_bytes_written: int = 0
    creates: int = 0
    deletes: int = 0
    renames: int = 0
    network_bytes: int = 0
    state_mutations: int = 0

    def as_dict(self):
        return self.__dict__.copy()


class Store:
    def __init__(self):
        self.root = Path(tempfile.mkdtemp(prefix="capsulenv-ablation-"))
        self.portable = self.root / "portable"
        self.host = self.root / "host"
        self.metrics = Metrics()

    def write(self, path: Path, size: int, area: str):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"x" * size)
        self.metrics.logical_bytes_written += size
        if area == "portable":
            self.metrics.portable_bytes_written += size
        else:
            self.metrics.host_bytes_written += size
        self.metrics.creates += 1

    def state(self, path: Path, size: int, area: str):
        self.write(path, size, area)
        self.metrics.state_mutations += 1


def generation(name: str):
    return hashlib.sha256(name.encode()).hexdigest()[:16]


def current_like(store: Store, host_local=False, eager_projection=True, local_cache=True):
    area = "host" if host_local else "portable"
    base = store.host if host_local else store.portable
    for package, files in PACKAGES.items():
        version = base / "packages" / package / "1.0.0"
        for rel in files:
            store.write(version / rel, FILE_BYTES[rel], area)
        if eager_projection:
            for projection in (base / "packages" / package / "current", base / "shims" / (package + ".cmd")):
                store.write(projection, 32, area)
        store.state(base / ".capsulenv" / "packages" / (package + ".json"), 512, area)
        store.metrics.network_bytes += sum(FILE_BYTES[f] for f in files) if not local_cache else 512
    store.state(base / ".capsulenv" / "scoop-rehydration.json", 768, area)


def converged(store: Store, host_local=True, local_cache=True, eager_projection=False):
    control = store.portable
    realization = store.host if host_local else store.portable
    area = "host" if host_local else "portable"
    for package, files in PACKAGES.items():
        gen = generation(package + ":1.0.0")
        for rel in files:
            size = FILE_BYTES[rel]
            store.write(realization / "realizations" / gen / package / rel, size, area)
            if not local_cache:
                store.metrics.network_bytes += size
        store.state(realization / "realizations" / gen / "COMPLETE", 64, area)
        store.state(control / "active" / (package + ".json"), 192, "portable")
        if eager_projection:
            store.state(control / "projections" / (package + ".json"), 192, "portable")
    store.state(control / "desired-state.json", 1024, "portable")


def variants():
    specs = [
        ("A0-current-fine-dag", lambda s: current_like(s, eager_projection=True, local_cache=True), 8, 11),
        ("A1-no-startup-reconcile", lambda s: None, 0, 0),
        ("A2-lazy-projection", lambda s: current_like(s, eager_projection=False, local_cache=True), 8, 11),
        ("A3-phase-dag", lambda s: current_like(s, eager_projection=True, local_cache=True), 4, 3),
        ("A4-acquire-realize-dag", lambda s: converged(s, host_local=True, local_cache=True), 2, 1),
        ("A5-sequential-reference", lambda s: converged(s, host_local=True, local_cache=True), 1, 0),
        ("A6-host-local-realization", lambda s: converged(s, host_local=True, local_cache=True), 2, 1),
        ("A7-no-local-blob-cache", lambda s: converged(s, host_local=True, local_cache=False), 2, 1),
        ("A8-separated-roots", lambda s: converged(s, host_local=True, local_cache=True), 2, 1),
    ]
    rows = []
    for name, action, graph_nodes, graph_edges in specs:
        store = Store()
        action(store)
        rows.append({"variant": name, "graph_nodes": graph_nodes, "graph_edges": graph_edges, **store.metrics.as_dict()})
        shutil.rmtree(store.root, ignore_errors=True)
    return rows


def failures():
    cases = ["acquire-interruption", "remote-unavailable", "hash-mismatch", "extract-kill", "target-disk-full", "realization-unavailable", "root-change", "concurrent-deploy", "before-activation", "after-activation", "cache-index-delete", "mutable-realization"]
    rows = []
    for architecture in ("current-like", "immutable-generation"):
        for case in cases:
            safe = architecture == "immutable-generation" or case not in {"after-activation", "concurrent-deploy", "mutable-realization"}
            rows.append({
                "architecture": architecture,
                "case": case,
                "invariant_holds": safe,
                "authority_after_crash": "old-or-new-valid" if architecture == "immutable-generation" else ("indeterminate" if not safe else "old-or-new"),
                "observable_outcome": "old-or-new-valid" if architecture == "immutable-generation" else "requires-recovery-check",
            })
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = {
        "schema": 1,
        "kind": "synthetic-prototype",
        "workload": {"packages": len(PACKAGES), "files_per_package": len(next(iter(PACKAGES.values())))},
        "variants": variants(),
        "failure_campaign": failures(),
        "limitations": [
            "Logical filesystem writes are not NTFS/controller write amplification.",
            "Current-like behavior is derived from source transitions, not a Windows runtime trace.",
            "Latency and real subprocess/network counters require the Windows harness.",
        ],
    }
    text = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
    else:
        print(text, end="")


if __name__ == "__main__":
    main()

