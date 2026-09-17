/root/.profile: line 11: /workspace/scratch/9406dad8be21/.cargo/env: No such file or directory
#!/usr/bin/env python3
"""Minimal immutable realization/publish/activation prototype."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import threading
from pathlib import Path


class GenerationManager:
    def __init__(self, root: str | Path):
        self.root = Path(root)
        self.realizations = self.root / "realizations"
        self.active_path = self.root / "active.json"
        self.realizations.mkdir(parents=True, exist_ok=True)
        # This is intentionally process-local.  The prototype is used to
        # test authority ordering; cross-process locking is a separate
        # Windows implementation experiment, not silently implied here.
        self._lock = threading.RLock()

    def generation_id(self, files: dict[str, bytes]) -> str:
        digest = hashlib.sha256()
        for name in sorted(files):
            digest.update(name.encode())
            digest.update(b"\0")
            digest.update(files[name])
        return digest.hexdigest()

    def _complete(self, generation: str) -> Path:
        return self.realizations / generation / "COMPLETE"

    def is_valid(self, generation: str) -> bool:
        marker = self._complete(generation)
        if not marker.is_file():
            return False
        try:
            manifest = json.loads(marker.read_text(encoding="utf-8"))
            if manifest.get("generation") != generation:
                return False
            generation_root = marker.parent
            for name, expected in manifest["files"].items():
                path = generation_root / name
                if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
                    return False
            return True
        except (OSError, ValueError, KeyError, json.JSONDecodeError):
            return False

    def active(self) -> str | None:
        if not self.active_path.is_file():
            return None
        try:
            payload = json.loads(self.active_path.read_text(encoding="utf-8"))
        except (OSError, ValueError, json.JSONDecodeError):
            return None
        generation = payload.get("generation")
        if generation and self.is_valid(generation):
            return generation
        # A corrupted/mutated active realization must not become authority.
        # The last known valid generation is retained in the pointer so a
        # startup verifier can safely fall back without scanning all history.
        previous = payload.get("previous")
        return previous if previous and self.is_valid(previous) else None

    def realize_publish(self, files: dict[str, bytes], generation: str, crash_after: str | None = None):
        temporary = self.realizations / (generation + ".partial")
        final = self.realizations / generation
        if final.exists() and self.is_valid(generation):
            return
        if temporary.exists():
            shutil.move(str(temporary), str(temporary.with_name(temporary.name + ".stale")))
        temporary.mkdir(parents=True)
        manifest = {}
        for name, data in files.items():
            path = temporary / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            manifest[name] = hashlib.sha256(data).hexdigest()
        if crash_after == "realize":
            raise RuntimeError("injected crash after realize")
        (temporary / "COMPLETE").write_text(
            json.dumps({"generation": generation, "files": manifest}, sort_keys=True),
            encoding="utf-8",
        )
        if crash_after == "publish":
            raise RuntimeError("injected crash before publish")
        if final.exists():
            raise RuntimeError("generation directory already exists but is not valid")
        os.replace(temporary, final)
        if not self.is_valid(generation):
            raise RuntimeError("published generation failed validation")

    def activate(self, generation: str, crash_after: str | None = None):
        with self._lock:
            if not self.is_valid(generation):
                raise RuntimeError("cannot activate incomplete generation")
            if crash_after == "before-activation":
                raise RuntimeError("injected crash before activation")
            old = self.active()
            temporary = self.active_path.with_suffix(".tmp")
            temporary.write_text(
                json.dumps({"generation": generation, "previous": old}, sort_keys=True),
                encoding="utf-8",
            )
            os.replace(temporary, self.active_path)
            if crash_after in {"after-activation", "post-activation"}:
                raise RuntimeError("injected crash after activation")

    def deploy(self, files: dict[str, bytes], crash_after: str | None = None) -> str:
        with self._lock:
            generation = self.generation_id(files)
            self.realize_publish(files, generation, crash_after=crash_after)
            self.activate(generation, crash_after=crash_after)
            return generation
