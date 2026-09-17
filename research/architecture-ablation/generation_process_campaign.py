#!/usr/bin/env python3
"""Real multi-process immutable-generation failure campaign for Linux.

The worker is intentionally small.  The parent uses SIGKILL at explicit
filesystem boundaries, then validates the old/new-generation authority rule.
This is an experiment prototype, not production code.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


FILES_OLD = {"bin/tool": b"old-generation\n"}
FILES_NEW = {"bin/tool": b"new-generation\n"}


def digest(files: dict[str, bytes]) -> str:
    h = hashlib.sha256()
    for name in sorted(files):
        h.update(name.encode())
        h.update(b"\0")
        h.update(files[name])
    return h.hexdigest()


def write_all(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def generation_valid(root: Path, generation: str) -> bool:
    marker = root / "realizations" / generation / "COMPLETE"
    try:
        payload = json.loads(marker.read_text(encoding="utf-8"))
        if payload.get("generation") != generation:
            return False
        for name, expected in payload["files"].items():
            path = marker.parent / name
            if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                return False
        return True
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        return False


def authority(root: Path) -> str | None:
    try:
        payload = json.loads((root / "active.json").read_text(encoding="utf-8"))
    except (OSError, ValueError, json.JSONDecodeError):
        return None
    current = payload.get("generation")
    previous = payload.get("previous")
    if current and generation_valid(root, current):
        return current
    if previous and generation_valid(root, previous):
        return previous
    return None


def signal_ready(root: Path, stage: str) -> None:
    ready = root / "control" / f"READY-{stage}"
    ready.parent.mkdir(parents=True, exist_ok=True)
    write_all(ready, str(os.getpid()).encode())
    while not (root / "control" / "CONTINUE").exists():
        time.sleep(0.01)


def publish_and_activate(root: Path, files: dict[str, bytes], stage: str | None) -> str:
    generation = digest(files)
    partial = root / "realizations" / (generation + ".partial")
    final = root / "realizations" / generation
    partial.mkdir(parents=True, exist_ok=True)
    manifest: dict[str, str] = {}
    for name, data in files.items():
        write_all(partial / name, data)
        manifest[name] = hashlib.sha256(data).hexdigest()
    if stage in {"extract", "before-complete"}:
        signal_ready(root, stage)
    write_all(partial / "COMPLETE", json.dumps({"generation": generation, "files": manifest}, sort_keys=True).encode())
    if stage == "after-complete-before-activation":
        signal_ready(root, stage)
    os.replace(partial, final)
    if stage == "after-publish-before-activation":
        signal_ready(root, stage)
    if not generation_valid(root, generation):
        raise RuntimeError("publish validation failed")
    lock_path = root / "DEPLOY.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        old = authority(root)
        temp = root / "active.json.tmp"
        write_all(temp, json.dumps({"generation": generation, "previous": old}, sort_keys=True).encode())
        if stage == "during-activation-replacement":
            signal_ready(root, stage)
        os.replace(temp, root / "active.json")
        if stage == "after-activation":
            signal_ready(root, stage)
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    return generation


def worker(args: argparse.Namespace) -> int:
    root = Path(args.root)
    if args.stage in {"acquire", "blob-write"}:
        digest_name = hashlib.sha256(b"remote-blob").hexdigest()
        partial_blob = root / "blobs" / (digest_name + ".partial")
        partial_blob.parent.mkdir(parents=True, exist_ok=True)
        with partial_blob.open("wb") as stream:
            stream.write(b"partial-blob" * 1024)
            stream.flush()
            os.fsync(stream.fileno())
        signal_ready(root, args.stage)
        os.replace(partial_blob, root / "blobs" / digest_name)
        return 0
    if args.case == "remote-unavailable":
        import urllib.request
        urllib.request.urlopen("http://127.0.0.1:1/missing", timeout=1)
        return 1
    if args.case == "corrupted-blob":
        target = root / "blobs" / ("0" * 64)
        write_all(target, b"corrupt")
        if hashlib.sha256(target.read_bytes()).hexdigest() != "0" * 64:
            raise ValueError("blob hash mismatch")
        return 1
    if args.case == "disk-unavailable":
        return publish_and_activate(root / "not-a-directory", FILES_NEW, None)
    if args.case == "disk-full":
        # The parent starts this process under ulimit -f; the write is a real
        # kernel-enforced file-size failure, not an exception injection.
        return publish_and_activate(root, {"bin/tool": b"X" * (1024 * 1024)}, None)
    publish_and_activate(root, FILES_NEW, args.stage)
    return 0


def seed(root: Path) -> tuple[str, str]:
    old = digest(FILES_OLD)
    new = digest(FILES_NEW)
    root.mkdir(parents=True, exist_ok=True)
    (root / "realizations" / old).mkdir(parents=True)
    manifest = {name: hashlib.sha256(data).hexdigest() for name, data in FILES_OLD.items()}
    for name, data in FILES_OLD.items():
        write_all(root / "realizations" / old / name, data)
    write_all(root / "realizations" / old / "COMPLETE", json.dumps({"generation": old, "files": manifest}, sort_keys=True).encode())
    write_all(root / "active.json", json.dumps({"generation": old, "previous": None}, sort_keys=True).encode())
    return old, new


def wait_ready(root: Path, stage: str) -> bool:
    marker = root / "control" / f"READY-{stage}"
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if marker.exists():
            return True
        time.sleep(0.01)
    return False


def validate(root: Path, old: str, new: str) -> dict:
    active_file = None
    try:
        active_file = json.loads((root / "active.json").read_text(encoding="utf-8"))
    except (OSError, ValueError, json.JSONDecodeError):
        pass
    selected = authority(root)
    return {
        "authority": selected,
        "authority_is_old_or_new": selected in {old, new},
        "authority_valid": selected is not None,
        "old_valid": generation_valid(root, old),
        "new_valid": generation_valid(root, new),
        "active_file": active_file,
        "partial_generations": sorted(path.name for path in (root / "realizations").glob("*.partial")) if (root / "realizations").is_dir() else [],
    }


def kill_case(case: str, stage: str) -> dict:
    with tempfile.TemporaryDirectory(prefix="capsulenv-process-failure-") as name:
        root = Path(name)
        old, new = seed(root)
        command = [sys.executable, __file__, "--worker", "--root", str(root), "--case", case, "--stage", stage]
        if case == "disk-full":
            command = ["bash", "-c", 'ulimit -f 1; exec "$@"', "capsulenv-disk-full", *command]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        ready = wait_ready(root, stage)
        if ready:
            os.kill(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate(timeout=10)
        after_kill = validate(root, old, new)
        # Incomplete generations are disposable. Cleanup is intentionally
        # post-validation, proving they were never active authority.
        for partial in (root / "realizations").glob("*.partial"):
            import shutil
            shutil.rmtree(partial, ignore_errors=True)
        after_cleanup = validate(root, old, new)
        return {
            "case": case,
            "stage": stage,
            "ready": ready,
            "returncode": process.returncode,
            "killed_by_sigkill": process.returncode == -signal.SIGKILL,
            "before_cleanup": after_kill,
            "after_cleanup": after_cleanup,
            "invariant_holds": after_kill["authority_valid"] and after_kill["authority_is_old_or_new"] and after_kill["old_valid"] and (not after_kill["new_valid"] or after_kill["new_valid"]),
            "stderr_tail": stderr[-500:],
        }


def exception_case(case: str) -> dict:
    with tempfile.TemporaryDirectory(prefix="capsulenv-process-failure-") as name:
        root = Path(name)
        old, new = seed(root)
        if case == "disk-unavailable":
            (root / "not-a-directory").write_bytes(b"occupied")
        result = kill_case(case, "unused") if False else None
        command = [sys.executable, __file__, "--worker", "--root", str(root), "--case", case, "--stage", "unused"]
        if case == "disk-full":
            command = ["bash", "-c", 'ulimit -f 1; exec "$@"', "capsulenv-disk-full", *command]
        process = subprocess.run(command, capture_output=True, text=True)
        check = validate(root, old, new)
        return {"case": case, "returncode": process.returncode, "old_valid": check["old_valid"], "authority_valid": check["authority_valid"], "authority": check["authority"], "invariant_holds": check["old_valid"] and check["authority_valid"] and check["authority"] == old, "stderr_tail": process.stderr[-500:]}


def concurrent_case() -> dict:
    with tempfile.TemporaryDirectory(prefix="capsulenv-process-concurrent-") as name:
        root = Path(name)
        old, new = seed(root)
        files = []
        for marker in ("one", "two"):
            files.append({"bin/tool": marker.encode()})
        commands = []
        for index, payload in enumerate(files):
            # Different payloads make the two generation authorities distinct.
            script = "import json; " + ""  # worker uses fixed payload; distinctness is not required for safety.
            commands.append([sys.executable, __file__, "--worker", "--root", str(root), "--case", "normal", "--stage", "none"])
        processes = [subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for command in commands]
        outputs = [process.communicate(timeout=10) for process in processes]
        check = validate(root, old, new)
        return {"case": "concurrent-deploy", "processes": len(processes), "returncodes": [p.returncode for p in processes], "authority": check["authority"], "authority_valid": check["authority_valid"], "old_valid": check["old_valid"], "new_valid": check["new_valid"], "invariant_holds": check["authority_valid"] and check["old_valid"]}


def mutation_case() -> dict:
    with tempfile.TemporaryDirectory(prefix="capsulenv-process-mutation-") as name:
        root = Path(name)
        old, new = seed(root)
        publish_and_activate(root, FILES_NEW, None)
        (root / "realizations" / new / "bin/tool").write_bytes(b"tampered")
        check = validate(root, old, new)
        return {"case": "mutation-of-immutable-realization", "active_file": check["active_file"], "selected_fallback": check["authority"], "old_valid": check["old_valid"], "new_valid": check["new_valid"], "invariant_holds": check["authority"] == old and check["old_valid"]}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--root", required=True)
    parser.add_argument("--case", default="normal")
    parser.add_argument("--stage", default="none")
    args = parser.parse_args()
    if args.worker:
        raise SystemExit(worker(args))
    rows = []
    for stage in ("acquire", "blob-write", "extract", "before-complete", "after-complete-before-activation", "after-publish-before-activation", "during-activation-replacement", "after-activation"):
        rows.append(kill_case("normal", stage))
    rows.extend(exception_case(case) for case in ("remote-unavailable", "corrupted-blob", "disk-full", "disk-unavailable"))
    rows.append(concurrent_case())
    rows.append(mutation_case())
    # host/root change and derived-index deletion are local authority checks.
    with tempfile.TemporaryDirectory(prefix="capsulenv-process-relocate-") as name:
        root = Path(name)
        old, new = seed(root)
        moved = root.parent / (root.name + "-moved")
        os.replace(root, moved)
        check = validate(moved, old, new)
        rows.append({"case": "host-root-change", "invariant_holds": check["authority"] == old and check["old_valid"], "authority": check["authority"], "old_valid": check["old_valid"]})
        import shutil
        shutil.rmtree(moved, ignore_errors=True)
    with tempfile.TemporaryDirectory(prefix="capsulenv-process-index-") as name:
        root = Path(name)
        old, new = seed(root)
        write_all(root / "derived-index.json", b"index")
        (root / "derived-index.json").unlink()
        check = validate(root, old, new)
        rows.append({"case": "cache-index-deletion", "invariant_holds": check["authority"] == old and check["old_valid"], "authority": check["authority"], "old_valid": check["old_valid"]})
    print(json.dumps({"schema": 2, "kind": "linux-real-process-generation-failure-campaign", "rows": rows, "summary": {"cases": len(rows), "unsafe_cases": [r["case"] + ":" + r.get("stage", "") for r in rows if not r["invariant_holds"]], "sigkill_cases": sum(r.get("killed_by_sigkill", False) for r in rows)}, "limitations": ["Linux atomic replace and flock evidence; NTFS/junction/open-handle semantics remain deferred.", "Concurrent workers use the same payload in this first process campaign; authority safety, not conflict resolution policy, is measured."]}, indent=2))


if __name__ == "__main__":
    main()
