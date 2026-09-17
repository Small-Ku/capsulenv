/root/.profile: line 11: /workspace/scratch/9406dad8be21/.cargo/env: No such file or directory
#!/usr/bin/env python3
"""Produce a source-backed compatibility/deletion matrix for legacy paths."""
from __future__ import annotations

import json
import re
from pathlib import Path


def functions(text: str) -> int:
    return len(re.findall(r"^function\s+[^\s{]+", text, re.M))


def main() -> None:
    root = Path(__file__).parents[2]
    files = {
        "legacy_projection": root / "src/46-LegacyScoopProjection.ps1",
        "relocation": root / "src/45-Relocation.ps1",
        "package_host_integration": root / "src/45-PackageHostIntegration.ps1",
        "package_executor": root / "src/44-PackageExecutor.ps1",
        "scoop_control": root / "src/40-Scoop.ps1",
    }
    inventory = {}
    for name, path in files.items():
        text = path.read_text(encoding="utf-8", errors="replace")
        inventory[name] = {
            "path": str(path.relative_to(root)).replace("\\", "/"),
            "lines": text.count("\n") + 1,
            "functions": functions(text),
            "mentions": {
                "legacy": len(re.findall(r"legacy", text, re.I)),
                "projection": len(re.findall(r"projection", text, re.I)),
                "relocation": len(re.findall(r"relocat", text, re.I)),
                "scoop": len(re.findall(r"scoop", text, re.I)),
            },
        }
    matrix = [
        {"surface": "Capsulenv-owned package projection", "path": "src/44-PackageExecutor.ps1", "observable_contract": "package launch/bin/persist mapping", "deletion_gate": "stable shim + active generation resolves all package bins", "classification": "preserve boundary; simplify implementation"},
        {"surface": "Legacy Scoop current/persist projection", "path": "src/46-LegacyScoopProjection.ps1", "observable_contract": "upstream Scoop user/global selectors and persist links", "deletion_gate": "no supported upstream Scoop-owned installation depends on it", "classification": "compatibility adapter; opt-in candidate"},
        {"surface": "Relocation fingerprint/inference", "path": "src/45-Relocation.ps1", "observable_contract": "drive/root/host change detection", "deletion_gate": "generation placement metadata replaces path inference without breaking relocation", "classification": "retain detection; remove duplicate repair paths only"},
        {"surface": "Shortcut/host integration", "path": "src/45-PackageHostIntegration.ps1", "observable_contract": "User-mode shortcuts and host registration", "deletion_gate": "stable resolver preserves shortcut targets and mode isolation", "classification": "compatibility boundary; runtime test required"},
        {"surface": "Scoop -g compatibility root", "path": "src/40-Scoop.ps1", "observable_contract": "unmodified upstream Scoop global selector", "deletion_gate": "explicitly unsupported or adapter isolated", "classification": "optional compatibility surface"},
    ]
    print(json.dumps({"schema": 1, "kind": "legacy-compatibility-source-audit", "inventory": inventory, "matrix": matrix, "evidence": "static source measured; no runtime compatibility claim"}, indent=2))


if __name__ == "__main__":
    main()
