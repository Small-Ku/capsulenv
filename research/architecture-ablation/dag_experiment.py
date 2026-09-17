/root/.profile: line 11: /workspace/scratch/9406dad8be21/.cargo/env: No such file or directory
#!/usr/bin/env python3
"""Run a real, local scheduler prototype for the four DAG shapes.

This is not a PowerShell or NTFS benchmark.  It measures the orchestration
cost of the same bounded file workload in a disposable directory, including
actual scheduling, file operations, and a configurable per-node work delay.
"""
from __future__ import annotations

import argparse
import json
import shutil
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path


PACKAGES = [f"pkg{i}" for i in range(1, 5)]


@dataclass
class Node:
    name: str
    deps: tuple[str, ...] = ()
    kind: str = "noop"


@dataclass
class Metrics:
    nodes: int
    edges: int
    wall_ms: float = 0.0
    file_creates: int = 0
    file_deletes: int = 0
    file_renames: int = 0
    bytes_written: int = 0
    state_mutations: int = 0
    max_parallelism: int = 0
    events: list[dict] = field(default_factory=list)


class Workload:
    def __init__(self, root: Path, metrics: Metrics, work_ms: float):
        self.root = root
        self.metrics = metrics
        self.work_ms = work_ms
        self._lock = threading.Lock()
        self._active = 0

    def run(self, node: Node) -> None:
        with self._lock:
            self._active += 1
            self.metrics.max_parallelism = max(self.metrics.max_parallelism, self._active)
        started = time.perf_counter()
        try:
            if self.work_ms:
                time.sleep(self.work_ms / 1000.0)
            if node.kind == "resolve":
                self._write("portable/desired-state.json", 1024, state=True)
            elif node.kind == "acquire":
                for package in PACKAGES:
                    self._write(f"portable/blobs/{package}.blob", 512)
            elif node.kind == "realize":
                for package in PACKAGES:
                    for index in range(5):
                        self._write(f"host/realizations/g/{package}/file-{index}", 1024 + index * 64)
            elif node.kind == "projection":
                for package in PACKAGES:
                    self._write(f"portable/projections/{package}.json", 192, state=True)
                    self._write(f"portable/shims/{package}.cmd", 64)
            elif node.kind == "activate":
                self._write("portable/active.json", 256, state=True)
            elif node.kind == "state":
                self._write("portable/rehydration-state.json", 768, state=True)
        finally:
            with self._lock:
                self._active -= 1
                self.metrics.events.append({
                    "node": node.name,
                    "kind": node.kind,
                    "duration_ms": round((time.perf_counter() - started) * 1000, 3),
                })

    def _write(self, relative: str, size: int, state: bool = False) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"x" * size)
        with self._lock:
            self.metrics.file_creates += 1
            self.metrics.bytes_written += size
            self.metrics.state_mutations += int(state)


def graphs() -> dict[str, list[Node]]:
    # The first graph mirrors the checked-in rehydrate topology (8/11).
    fine = [
        Node("session-environment", kind="resolve"),
        Node("user-environment-backup", ("session-environment",)),
        Node("package-projections", ("session-environment", "user-environment-backup"), "projection"),
        Node("persist-relocation", ("package-projections",), "state"),
        Node("project-cache-links", ("package-projections",), "state"),
        Node("tool-relocation", ("project-cache-links",), "realize"),
        Node("user-integration", ("persist-relocation", "tool-relocation")),
        Node("rehydration-state", ("persist-relocation", "tool-relocation", "user-integration"), "activate"),
    ]
    phase = [
        Node("resolve", kind="resolve"),
        Node("acquire", ("resolve",), "acquire"),
        Node("realize", ("acquire",), "realize"),
        Node("activate", ("realize",), "activate"),
    ]
    acquire_realize = [
        Node("acquire", kind="acquire"),
        Node("realize-and-activate", ("acquire",), "realize"),
    ]
    sequential = [Node("sequential-reference", kind="realize")]
    return {
        "current-fine-grained": fine,
        "phase-level": phase,
        "acquire-realize-only": acquire_realize,
        "sequential-reference": sequential,
    }


def execute(nodes: list[Node], root: Path, work_ms: float) -> Metrics:
    metrics = Metrics(nodes=len(nodes), edges=sum(len(n.deps) for n in nodes))
    workload = Workload(root, metrics, work_ms)
    pending = {node.name: node for node in nodes}
    completed: set[str] = set()
    started = time.perf_counter()
    with ThreadPoolExecutor(max_workers=max(1, len(nodes))) as pool:
        while pending:
            ready = [node for node in pending.values() if set(node.deps) <= completed]
            if not ready:
                raise RuntimeError("cycle or missing dependency")
            futures = {pool.submit(workload.run, node): node for node in ready}
            for future, node in futures.items():
                future.result()
                completed.add(node.name)
                del pending[node.name]
    metrics.wall_ms = round((time.perf_counter() - started) * 1000, 3)
    return metrics


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repetitions", type=int, default=7)
    parser.add_argument("--work-ms", type=float, default=2.0)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    rows = []
    for name, nodes in graphs().items():
        samples = []
        for _ in range(args.repetitions):
            root = Path(tempfile.mkdtemp(prefix="capsulenv-dag-"))
            try:
                samples.append(execute(nodes, root, args.work_ms).__dict__)
            finally:
                shutil.rmtree(root, ignore_errors=True)
        ordered = sorted(sample["wall_ms"] for sample in samples)
        row = {
            "variant": name,
            "nodes": samples[0]["nodes"],
            "edges": samples[0]["edges"],
            "repetitions": args.repetitions,
            "wall_p50_ms": ordered[(len(ordered) - 1) * 50 // 100],
            "wall_p95_ms": ordered[(len(ordered) - 1) * 95 // 100],
            "max_parallelism_observed": max(sample["max_parallelism"] for sample in samples),
            "samples": samples,
        }
        rows.append(row)
    result = {
        "schema": 1,
        "kind": "local-scheduler-prototype-measured",
        "work_ms": args.work_ms,
        "variants": rows,
        "limitations": [
            "Runs on local Linux filesystem, not Windows PowerShell or NTFS.",
            "The fine graph mirrors current node/edge topology but does not claim identical callback cost.",
            "Wall time includes a controlled synthetic per-node delay; use relative results only.",
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
