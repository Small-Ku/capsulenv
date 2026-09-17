#!/usr/bin/env python3
"""Real Linux filesystem/process workload used by the architecture campaign.

This is an experiment workload, not a replacement for the PowerShell module.
It deliberately exposes the same architectural boundaries: acquire immutable
blob, realize a generation, verify/publish, and switch a small authority file.
"""
from __future__ import annotations

import hashlib
import http.server
import json
import os
import shutil
import socketserver
import sys
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path


def payload(seed: str, size: int) -> bytes:
    block = hashlib.sha256(seed.encode()).digest()
    return (block * ((size // len(block)) + 1))[:size]


WORKLOADS = {
    "small": {
        f"pkg{i}": {
            "deps": ("pkg1",) if i > 1 else (),
            "files": {f"bin/{j}.bin": 4096 + j * 1024 for j in range(12)},
        }
        for i in range(1, 5)
    },
    "large": {
        "base": {"deps": (), "files": {"lib/base.bin": 4 * 1024 * 1024}},
        "tool-a": {"deps": ("base",), "files": {"bin/tool-a.bin": 4 * 1024 * 1024}},
        "tool-b": {"deps": ("base",), "files": {"bin/tool-b.bin": 4 * 1024 * 1024}},
        "tool-c": {"deps": ("tool-a", "tool-b"), "files": {"bin/tool-c.bin": 2 * 1024 * 1024}},
    },
}


@dataclass
class Metrics:
    logical_bytes_written: int = 0
    portable_bytes_written: int = 0
    host_bytes_written: int = 0
    network_bytes: int = 0
    network_requests: int = 0
    file_creates: int = 0
    file_overwrites: int = 0
    file_deletes: int = 0
    file_renames: int = 0
    metadata_operations: int = 0
    state_mutations: int = 0
    fsync_count: int = 0
    max_concurrency: int = 0
    package_events: list[dict] = field(default_factory=list)


class Runtime:
    def __init__(self, root: str | Path, workload: str = "small", placement: str = "all-portable"):
        self.root = Path(root)
        self.packages = WORKLOADS[workload]
        self.placement = placement
        self.metrics = Metrics()
        self._lock = threading.Lock()
        self._active_workers = 0
        self._remote_server: socketserver.TCPServer | None = None
        self._remote_thread: threading.Thread | None = None
        self._remote_port: int | None = None
        self._source_root = self.root / "remote-source"
        self._acquired_data: dict[str, bytes] = {}

    @property
    def portable(self) -> Path:
        return self.root / "portable"

    @property
    def host(self) -> Path:
        return self.root / "host"

    @property
    def home(self) -> Path:
        return self.portable / "capsule-home"

    @property
    def blob_root(self) -> Path | None:
        if self.placement == "host-realization-remote-blobs":
            return None
        if self.placement == "host-realization-host-blobs":
            return self.host / "blob-store"
        return self.portable / "blob-store"

    @property
    def realization_root(self) -> Path:
        return self.host / "realizations" if self.placement != "all-portable" else self.portable / "realizations"

    @property
    def state_root(self) -> Path:
        return self.home / "state"

    @property
    def scratch_root(self) -> Path:
        return self.host / "scratch" if self.placement != "all-portable" else self.portable / "scratch"

    def setup(self) -> None:
        for path in (self.home, self.state_root, self.scratch_root, self._source_root):
            path.mkdir(parents=True, exist_ok=True)
        self.metrics.metadata_operations += 4
        for package, spec in self.packages.items():
            data = b"".join(payload(package + ":" + name, size) for name, size in spec["files"].items())
            (self._source_root / (package + ".blob")).write_bytes(data)

    def _area(self, path: Path) -> str:
        try:
            relative = path.relative_to(self.root)
        except ValueError:
            return "external"
        return "portable" if relative.parts and relative.parts[0] == "portable" else "host"

    def write(self, path: Path, data: bytes, state: bool = False, sync: bool = False) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.metrics.metadata_operations += 1
        exists = path.exists()
        with path.open("wb") as stream:
            stream.write(data)
            if sync:
                stream.flush()
                os.fsync(stream.fileno())
                self.metrics.fsync_count += 1
        with self._lock:
            self.metrics.logical_bytes_written += len(data)
            area = self._area(path)
            if area == "portable":
                self.metrics.portable_bytes_written += len(data)
            elif area == "host":
                self.metrics.host_bytes_written += len(data)
            if exists:
                self.metrics.file_overwrites += 1
            else:
                self.metrics.file_creates += 1
            if state or any(token in str(path).lower() for token in ("active", "state", "complete", "desired", "manifest", "index", "projection", "shim")):
                self.metrics.state_mutations += 1

    def replace(self, source: Path, destination: Path) -> None:
        destination.parent.mkdir(parents=True, exist_ok=True)
        os.replace(source, destination)
        with self._lock:
            self.metrics.file_renames += 1
            self.metrics.metadata_operations += 1

    def start_remote(self) -> None:
        if self._remote_server is not None:
            return
        handler = http.server.SimpleHTTPRequestHandler
        directory = str(self._source_root)

        class Handler(handler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=directory, **kwargs)

            def log_message(self, *_args):
                return

        self._remote_server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        self._remote_port = int(self._remote_server.server_address[1])
        self._remote_thread = threading.Thread(target=self._remote_server.serve_forever, daemon=True)
        self._remote_thread.start()

    def stop_remote(self) -> None:
        if self._remote_server is not None:
            self._remote_server.shutdown()
            self._remote_server.server_close()
            self._remote_server = None

    def acquire(self, package: str) -> None:
        started = time.perf_counter()
        source = self._source_root / (package + ".blob")
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        if self.placement == "host-realization-remote-blobs":
            self.start_remote()
            url = f"http://127.0.0.1:{self._remote_port}/{source.name}"
            data = urllib.request.urlopen(url, timeout=30).read()
            self.metrics.network_bytes += len(data)
            self.metrics.network_requests += 1
        else:
            data = source.read_bytes()
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError(f"acquired blob hash mismatch: {package}")
        self._acquired_data[package] = data
        if self.blob_root is not None:
            target = self.blob_root / digest[:2] / digest
            if not target.exists():
                self.write(target, data, sync=True)
            elif hashlib.sha256(target.read_bytes()).hexdigest() != digest:
                raise ValueError(f"cached blob corruption: {package}")
        self.metrics.package_events.append({"phase": "acquire", "package": package, "duration_ms": round((time.perf_counter() - started) * 1000, 3)})

    def realize(self, package: str) -> None:
        started = time.perf_counter()
        spec = self.packages[package]
        for dependency in spec["deps"]:
            dependency_generation = hashlib.sha256(dependency.encode()).hexdigest()[:16]
            if not (self.realization_root / dependency_generation / dependency).is_dir():
                raise RuntimeError(f"dependency realization is not ready: {package} -> {dependency}")
        generation = hashlib.sha256(package.encode()).hexdigest()[:16]
        partial = self.realization_root / (generation + ".partial") / package
        final = self.realization_root / generation / package
        if final.exists():
            self.metrics.package_events.append({"phase": "realize-skip", "package": package, "duration_ms": round((time.perf_counter() - started) * 1000, 3)})
            return
        source_blob = self._acquired_data.get(package)
        if source_blob is None:
            source_blob = payload(package + ":blob", sum(spec["files"].values()))
        offset = 0
        for name, size in spec["files"].items():
            self.write(partial / name, source_blob[offset : offset + size])
            offset += size
        complete = partial.parent / "COMPLETE"
        manifest = {name: hashlib.sha256(payload(package + ":" + name, size)).hexdigest() for name, size in spec["files"].items()}
        self.write(complete, json.dumps({"package": package, "files": manifest}, sort_keys=True).encode(), state=True, sync=True)
        self.replace(partial.parent, self.realization_root / generation)
        self.metrics.package_events.append({"phase": "realize", "package": package, "duration_ms": round((time.perf_counter() - started) * 1000, 3)})

    def active_generation(self) -> dict:
        return {package: hashlib.sha256(package.encode()).hexdigest()[:16] for package in self.packages}

    def activate(self) -> None:
        payload_data = json.dumps(self.active_generation(), sort_keys=True).encode()
        temporary = self.state_root / "active.json.partial"
        self.write(temporary, payload_data, state=True, sync=True)
        self.replace(temporary, self.state_root / "active.json")

    def _task(self, phase: str, package: str) -> None:
        with self._lock:
            self._active_workers += 1
            self.metrics.max_concurrency = max(self.metrics.max_concurrency, self._active_workers)
        try:
            if phase == "acquire":
                self.acquire(package)
            else:
                self.realize(package)
        finally:
            with self._lock:
                self._active_workers -= 1

    def deploy(self, mode: str = "sequential", workers: int = 2) -> dict:
        started = time.perf_counter()
        self.setup()
        if self.placement == "host-realization-remote-blobs":
            self.start_remote()
        packages = list(self.packages)
        if mode == "sequential":
            for package in packages:
                self._task("acquire", package)
            for package in packages:
                self._task("realize", package)
        elif mode == "bounded":
            # Phase-level reference: acquire is one phase; realization is
            # scheduled in dependency waves, preserving correctness without
            # exposing each acquire edge to the scheduler.
            with ThreadPoolExecutor(max_workers=workers) as pool:
                list(pool.map(lambda package: self._task("acquire", package), packages))
                completed_packages: set[str] = set()
                while len(completed_packages) < len(packages):
                    wave = [package for package in packages if package not in completed_packages and set(self.packages[package]["deps"]) <= completed_packages]
                    if not wave:
                        raise RuntimeError("phase dependency cycle")
                    list(pool.map(lambda package: self._task("realize", package), wave))
                    completed_packages.update(wave)
        elif mode == "ar-dag":
            # Acquire/Realize-only DAG: acquire tasks are independent; only
            # realization dependency edges are retained.
            completed: set[tuple[str, str]] = set()
            pending = {(phase, package) for package in packages for phase in ("acquire", "realize")}
            while pending:
                ready = []
                for task in pending:
                    phase, package = task
                    deps = set()
                    if phase == "realize":
                        deps.add(("acquire", package))
                        deps.update({("realize", dep) for dep in self.packages[package]["deps"]})
                    if deps <= completed:
                        ready.append(task)
                if not ready:
                    raise RuntimeError("Acquire/Realize DAG cycle")
                with ThreadPoolExecutor(max_workers=workers) as pool:
                    futures = [pool.submit(self._task, phase, package) for phase, package in ready]
                    for future in futures:
                        future.result()
                for task in ready:
                    pending.remove(task)
                    completed.add(task)
        elif mode == "dag":
            completed: set[tuple[str, str]] = set()
            pending = {(phase, package) for package in packages for phase in ("acquire", "realize")}
            while pending:
                ready = []
                for task in pending:
                    phase, package = task
                    deps = set()
                    # The current fine-grained graph also orders acquisition by
                    # package dependency. The Acquire/Realize-only graph does
                    # not: its only acquire dependency is the source itself.
                    if phase == "acquire":
                        deps = {("acquire", dep) for dep in self.packages[package]["deps"]}
                    if phase == "realize":
                        deps.add(("acquire", package))
                        deps.update({("realize", dep) for dep in self.packages[package]["deps"]})
                    if deps <= completed:
                        ready.append(task)
                if not ready:
                    raise RuntimeError("package DAG cycle")
                with ThreadPoolExecutor(max_workers=workers) as pool:
                    futures = [pool.submit(self._task, phase, package) for phase, package in ready]
                    for future in futures:
                        future.result()
                for task in ready:
                    pending.remove(task)
                    completed.add(task)
        else:
            raise ValueError(mode)
        self.activate()
        self.stop_remote()
        dag_nodes = len(packages) * 2
        if mode == "sequential":
            dag_edges = 0
            dag_waves = 0
        elif mode in {"bounded", "ar-dag"}:
            dag_edges = len(packages)
            dag_waves = 2
        else:
            dag_edges = sum(len(self.packages[p]["deps"]) for p in packages) + len(packages)
            dag_edges += sum(len(self.packages[p]["deps"]) for p in packages)
            dag_waves = len({event["phase"] for event in self.metrics.package_events if event["phase"] in {"acquire", "realize"}})
        return {
            "wall_ms": round((time.perf_counter() - started) * 1000, 3),
            "dag_nodes": dag_nodes,
            "dag_edges": dag_edges,
            "dag_waves": dag_waves,
            "dag_max_concurrency": self.metrics.max_concurrency,
            **self.metrics.__dict__,
        }

    def startup(self, mode: str) -> dict:
        started = time.perf_counter()
        active = json.loads((self.state_root / "active.json").read_text(encoding="utf-8"))
        for package, generation in active.items():
            target = self.realization_root / generation / package
            if not target.is_dir():
                raise ValueError(f"invalid active generation: {package}")
            self.metrics.metadata_operations += 1
            if mode == "auto":
                self.write(self.home / "projections" / (package + ".json"), json.dumps({"package": package, "generation": generation}).encode(), state=True)
                self.write(self.home / "shims" / (package + ".cmd"), f"resolve {package} {generation}\n".encode(), state=True)
        if mode not in {"auto", "validate"}:
            raise ValueError(mode)
        return {"wall_ms": round((time.perf_counter() - started) * 1000, 3), **self.metrics.__dict__}


def command(root: str, operation: str, mode: str = "sequential", workload: str = "small", placement: str = "all-portable", workers: int = 2) -> dict:
    runtime = Runtime(root, workload, placement)
    if operation == "deploy":
        return runtime.deploy(mode, workers)
    if operation == "startup":
        return runtime.startup(mode)
    raise ValueError(operation)


def main() -> None:
    if "--server" in sys.argv:
        args = {sys.argv[i][2:]: sys.argv[i + 1] for i in range(1, len(sys.argv) - 1) if sys.argv[i].startswith("--")}
        for line in sys.stdin:
            request = json.loads(line)
            try:
                result = command(args["root"], request["operation"], request.get("mode", "sequential"), request.get("workload", "small"), request.get("placement", "all-portable"), request.get("workers", 2))
                print(json.dumps({"ok": True, "result": result}), flush=True)
            except Exception as exc:
                print(json.dumps({"ok": False, "error": repr(exc)}), flush=True)
        raise SystemExit(0)
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--operation", choices=("deploy", "startup"), required=True)
    parser.add_argument("--mode", default="sequential")
    parser.add_argument("--workload", default="small")
    parser.add_argument("--placement", default="all-portable")
    parser.add_argument("--workers", type=int, default=2)
    args = parser.parse_args()
    print(json.dumps(command(args.root, args.operation, args.mode, args.workload, args.placement, args.workers)))


if __name__ == "__main__":
    main()
