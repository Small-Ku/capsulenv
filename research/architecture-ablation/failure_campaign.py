/root/.profile: line 11: /workspace/scratch/9406dad8be21/.cargo/env: No such file or directory
#!/usr/bin/env python3
"""Execute the research-only immutable-generation failure campaign.

The cases use real local file operations and injected exceptions.  They do not
pretend to reproduce Windows PowerShell, NTFS, rclone, or a physical disk
failure; those remain platform-specific follow-ups.
"""
from __future__ import annotations

import hashlib
import json
import shutil
import tempfile
import threading
from pathlib import Path

from blob_store import LocalBlobStore
from generation_prototype import GenerationManager


CASES = [
    "acquire-interruption",
    "remote-unavailable",
    "corrupted-hash-mismatched-blob",
    "extract-interruption",
    "target-disk-full",
    "realization-disk-unavailable",
    "host-root-change",
    "concurrent-deploy",
    "failure-before-activation",
    "failure-after-activation",
    "cache-index-deletion",
    "mutable-realization",
]


def valid_authority(manager: GenerationManager, expected: set[str]) -> bool:
    active = manager.active()
    return active in expected and active is not None and manager.is_valid(active)


def run_case(case: str) -> dict:
    relocated_to: Path | None = None
    with tempfile.TemporaryDirectory(prefix="capsulenv-failure-") as tmp:
        root = Path(tmp)
        manager = GenerationManager(root)
        old = manager.deploy({"bin/tool.exe": b"old"})
        new_files = {"bin/tool.exe": b"new"}
        new = manager.generation_id(new_files)
        expected = {old, new}
        detail = ""
        try:
            if case == "acquire-interruption" or case == "remote-unavailable":
                raise RuntimeError("injected before acquire completion")
            if case == "corrupted-hash-mismatched-blob":
                source = root / "source.bin"
                source.write_bytes(b"wrong")
                digest = hashlib.sha256(b"expected").hexdigest()
                LocalBlobStore(root / "blobs").put(digest, source)
            elif case == "extract-interruption":
                manager.deploy(new_files, crash_after="realize")
            elif case == "target-disk-full" or case == "realization-disk-unavailable":
                raise OSError("injected storage failure before publish")
            elif case == "host-root-change":
                relocated_to = root.parent / (root.name + "-relocated")
                shutil.move(str(root), str(relocated_to))
                manager = GenerationManager(relocated_to)
                detail = "authority remained valid after moving the realization root"
            elif case == "concurrent-deploy":
                results: list[str] = []

                def worker(data: bytes) -> None:
                    results.append(manager.deploy({"bin/tool.exe": data}))

                threads = [threading.Thread(target=worker, args=(b"one",)), threading.Thread(target=worker, args=(b"two",))]
                for thread in threads:
                    thread.start()
                for thread in threads:
                    thread.join()
                expected.update(results)
            elif case == "failure-before-activation":
                manager.realize_publish(new_files, new)
                manager.activate(new, crash_after="before-activation")
            elif case == "failure-after-activation":
                manager.realize_publish(new_files, new)
                manager.activate(new, crash_after="after-activation")
            elif case == "cache-index-deletion":
                cache = root / "derived-cache.json"
                cache.write_text(json.dumps({"generation": old}), encoding="utf-8")
                cache.unlink()
                detail = "derived cache deletion did not remove active authority"
            elif case == "mutable-realization":
                manager.deploy(new_files)
                (root / "realizations" / new / "bin" / "tool.exe").write_bytes(b"tampered")
                expected = {old, new}
        except (OSError, RuntimeError, ValueError):
            pass
        safe = valid_authority(manager, expected)
        result = {
            "case": case,
            "invariant_holds": safe,
            "active_after": manager.active(),
            "old_generation_valid": manager.is_valid(old),
            "new_generation_valid": manager.is_valid(new),
            "detail": detail,
            "evidence": "prototype-measured",
        }
    if relocated_to is not None:
        shutil.rmtree(relocated_to, ignore_errors=True)
    return result


def main() -> None:
    rows = [run_case(case) for case in CASES]
    print(json.dumps({
        "schema": 1,
        "kind": "immutable-generation-failure-campaign",
        "rows": rows,
        "summary": {
            "cases": len(rows),
            "unsafe_cases": [row["case"] for row in rows if not row["invariant_holds"]],
        },
        "limitations": [
            "Storage and remote failures are injected before the corresponding OS operation.",
            "Concurrent deploy is thread-level and does not test multiple processes.",
            "The current production architecture is not executed by this prototype.",
        ],
    }, indent=2))


if __name__ == "__main__":
    main()
