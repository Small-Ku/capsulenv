/root/.profile: line 11: /workspace/scratch/9406dad8be21/.cargo/env: No such file or directory
#!/usr/bin/env python3
"""Prototype the package-projection eager-vs-resolver tradeoff.

The resolver is deliberately tiny: it reads one active-generation metadata
record and produces a stable launcher target.  This does not replace the
production projection subsystem.
"""
from __future__ import annotations

import json
import shutil
import tempfile
from pathlib import Path


PACKAGES = {"git": "2.46.0", "jq": "1.7.1", "ripgrep": "14.1.0"}


def eager(root: Path) -> dict:
    for package, version in PACKAGES.items():
        (root / "projections").mkdir(parents=True, exist_ok=True)
        (root / "shims").mkdir(parents=True, exist_ok=True)
        (root / "projections" / f"{package}.json").write_text(
            json.dumps({"package": package, "version": version, "target": f"generations/{package}/{version}"}),
            encoding="utf-8",
        )
        (root / "shims" / f"{package}.cmd").write_text(
            f"@echo off\n\"%~dp0..\\generations\\{package}\\{version}\\{package}.exe\" %*\n",
            encoding="utf-8",
        )
    return snapshot(root)


def resolver(root: Path) -> dict:
    (root / "active.json").write_text(json.dumps(PACKAGES, sort_keys=True), encoding="utf-8")
    (root / "shim.cmd").write_text(
        "@echo off\nrem stable shim resolves package and active generation\n", encoding="utf-8"
    )
    return snapshot(root)


def snapshot(root: Path) -> dict:
    files = [p for p in root.rglob("*") if p.is_file()]
    return {
        "files": len(files),
        "bytes": sum(p.stat().st_size for p in files),
        "paths": sorted(str(p.relative_to(root)) for p in files),
    }


def resolve(root: Path, package: str) -> str:
    metadata = json.loads((root / "active.json").read_text(encoding="utf-8"))
    return f"generations/{package}/{metadata[package]}"


def main() -> None:
    rows = []
    for name, builder in (("eager", eager), ("stable-shim-resolver", resolver)):
        root = Path(tempfile.mkdtemp(prefix="capsulenv-projection-"))
        try:
            before = snapshot(root)
            after = builder(root)
            rows.append({"variant": name, "before": before, "after": after,
                         "resolved_targets": {p: resolve(root, p) if name != "eager" else f"generations/{p}/{v}"
                                               for p, v in PACKAGES.items()}})
        finally:
            shutil.rmtree(root, ignore_errors=True)
    print(json.dumps({
        "schema": 1,
        "kind": "projection-ablation-prototype-measured",
        "rows": rows,
        "limitations": [
            "The compatibility check covers only the synthetic launcher contract.",
            "It does not exercise Scoop shims, Start Menu shortcuts, or User-mode registration.",
        ],
    }, indent=2))


if __name__ == "__main__":
    main()
