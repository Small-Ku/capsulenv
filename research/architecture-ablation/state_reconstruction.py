/root/.profile: line 11: /workspace/scratch/9406dad8be21/.cargo/env: No such file or directory
#!/usr/bin/env python3
"""Test whether derived indexes can be deleted and reconstructed."""
from __future__ import annotations

import hashlib
import json
import shutil
import tempfile
from pathlib import Path


PACKAGES = {"git": b"git-generation", "jq": b"jq-generation", "ripgrep": b"rg-generation"}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def build_authority(root: Path) -> dict:
    generations = {}
    for package, data in PACKAGES.items():
        generation = digest(data)[:16]
        target = root / "realizations" / generation / package
        target.mkdir(parents=True, exist_ok=True)
        (target / "bin").write_bytes(data)
        (target.parent / "COMPLETE").write_text(json.dumps({"package": package, "digest": digest(data)}), encoding="utf-8")
        generations[package] = generation
    (root / "desired.json").write_text(json.dumps(generations, sort_keys=True), encoding="utf-8")
    (root / "active.json").write_text(json.dumps(generations, sort_keys=True), encoding="utf-8")
    return generations


def reconstruct_index(root: Path) -> dict:
    desired = json.loads((root / "desired.json").read_text(encoding="utf-8"))
    active = json.loads((root / "active.json").read_text(encoding="utf-8"))
    if desired != active:
        raise ValueError("authority mismatch")
    index = {}
    for package, generation in desired.items():
        marker = root / "realizations" / generation / "COMPLETE"
        payload = json.loads(marker.read_text(encoding="utf-8"))
        binary = marker.parent / package / "bin"
        if not binary.is_file() or digest(binary.read_bytes()) != payload["digest"]:
            raise ValueError("generation validation failed")
        index[package] = {"generation": generation, "target": str(binary)}
    return index


def run(mode: str) -> dict:
    with tempfile.TemporaryDirectory(prefix="capsulenv-state-") as tmp:
        root = Path(tmp)
        authority = build_authority(root)
        derived = reconstruct_index(root)
        (root / "index.json").write_text(json.dumps(derived, sort_keys=True), encoding="utf-8")
        if mode == "delete-index":
            (root / "index.json").unlink()
        elif mode == "delete-cache":
            (root / "cache.json").write_text("{}", encoding="utf-8")
            (root / "cache.json").unlink()
        elif mode == "mutate-index":
            (root / "index.json").write_text(json.dumps({"git": {"target": "wrong"}}), encoding="utf-8")
        observed = reconstruct_index(root)
        rebuilt = mode in {"delete-index", "mutate-index"}
        if rebuilt:
            (root / "index.json").write_text(json.dumps(observed, sort_keys=True), encoding="utf-8")
        return {
            "mode": mode,
            "observable_resolution_equal": observed == derived,
            "authority_unchanged": authority == json.loads((root / "active.json").read_text(encoding="utf-8")),
            "derived_index_rebuilt": rebuilt,
        }


def main() -> None:
    rows = [run(mode) for mode in ("baseline", "delete-index", "delete-cache", "mutate-index")]
    print(json.dumps({
        "schema": 1,
        "kind": "derived-state-reconstruction-prototype-measured",
        "rows": rows,
        "limitations": [
            "The authority is a bounded synthetic manifest/generation set.",
            "This does not prove every current Scoop state file is derivable.",
        ],
    }, indent=2))


if __name__ == "__main__":
    main()
