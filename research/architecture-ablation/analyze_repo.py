#!/usr/bin/env python3
"""Static architecture inventory for the capsulenv ablation campaign."""
from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path

ROOTS = ("src", "module-runtime", "packaging", "scripts", "tests", "config")
SIDE_EFFECT_PATTERNS = {
    "create_dir": r"New-Item\s+-ItemType\s+Directory",
    "write_content": r"Set-Content|Out-File|WriteAllText|WriteAllBytes",
    "replace": r"\.Replace\(|File\.Replace|Move-Item|Copy-Item",
    "delete": r"Remove-Item",
    "link": r"New-Item\s+-ItemType\s+(Junction|SymbolicLink)|DirectoryLink|FileLink",
    "subprocess": r"(^|\s)&\s|Start-Process|\.AddScript\(|ProcessStartInfo",
    "registry": r"Registry|Get-CapsulenvRegistry|Set-CapsulenvRegistry",
    "network": r"Invoke-WebRequest|Start-BitsTransfer|WebClient|HttpClient|curl|wget",
}


def read_files(root: Path):
    for top in ROOTS:
        base = root / top
        if base.exists():
            yield from sorted(base.rglob("*"))


def lines(text: str) -> int:
    return text.count("\n") + (1 if text and not text.endswith("\n") else 0)


def node_inventory(text: str):
    starts = list(re.finditer(r"New-CapsulenvDesiredStateNode\s+-Id\s+'([^']+)'", text))
    nodes = []
    for i, match in enumerate(starts):
        end = starts[i + 1].start() if i + 1 < len(starts) else len(text)
        block = text[match.start():end]
        deps = []
        one = re.search(r"-DependsOn\s+'([^']+)'", block)
        if one:
            deps.append(one.group(1))
        many = re.search(r"-DependsOn\s+@\(([^)]*)\)", block, re.S)
        if many:
            deps.extend(re.findall(r"'([^']+)'", many.group(1)))

        def resources(name):
            item = re.search(rf"-{name}\s+@\(([^)]*)\)", block, re.S)
            return re.findall(r"'([^']+)'", item.group(1)) if item else []

        nodes.append({
            "id": match.group(1),
            "depends_on": deps,
            "read_resources": resources("ReadResources"),
            "write_resources": resources("WriteResources"),
            "parallel_safe": bool(re.search(r"-ParallelSafe\b", block)),
        })
    return nodes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).parents[2])
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    files = list(read_files(root))
    texts = {
        str(path.relative_to(root)).replace("\\", "/"): path.read_text(encoding="utf-8", errors="replace")
        for path in files if path.is_file()
    }
    src_files = [path for path in files if path.suffix.lower() == ".ps1" and path.parts[-2] == "src"]
    side_effects = Counter()
    by_file = []
    functions = 0
    for rel, text in texts.items():
        if rel.startswith("src/"):
            functions += len(re.findall(r"^function\s+[^\s{]+", text, re.M))
        if rel.startswith("src/") or rel.startswith("module-runtime/"):
            row = {"path": rel, "lines": lines(text), "side_effects": {}}
            for name, pattern in SIDE_EFFECT_PATTERNS.items():
                value = len(re.findall(pattern, text, re.I | re.M))
                row["side_effects"][name] = value
                side_effects[name] += value
            by_file.append(row)

    nodes = node_inventory(texts.get("src/40-Scoop.ps1", ""))
    edges = [{"from": dep, "to": node["id"]} for node in nodes for dep in node["depends_on"]]
    config = texts.get("config/capsulenv.psd1", "")
    roots = {m.group(1): m.group(2) for m in re.finditer(
        r"^\s*(Root|GlobalRoot|Shims|Persist|Cache)\s*=\s*'([^']+)'", config, re.M
    )}
    result = {
        "schema": 1,
        "commit_expected": "2412f2a4f115eae2e1218c240a8d142e5013d458",
        "inventory": {
            "files_scanned": len(files),
            "source_files": len(src_files),
            "source_lines": sum(lines(texts[str(p.relative_to(root)).replace('\\', '/')]) for p in src_files),
            "test_files": len([p for p in files if p.name.endswith(".Tests.ps1")]),
            "function_count": functions,
            "configured_storage_roots": roots,
            "package_projection_function_count": sum(
                len(re.findall(r"^function\s+[^\s{]+", texts.get(path, ""), re.M))
                for path in texts if re.match(r"src/(43|44|45|46)-", path)
            ),
            "legacy_or_relocation_function_count": sum(
                len(re.findall(r"^function\s+[^\s{]+", texts.get(path, ""), re.M))
                for path in texts if "Legacy" in path or "Relocation" in path
            ),
        },
        "rehydrate_graph": {
            "node_count": len(nodes),
            "edge_count": len(edges),
            "nodes": nodes,
            "edges": edges,
            "parallel_safe_nodes": [n["id"] for n in nodes if n["parallel_safe"]],
            "resource_claim_count": sum(len(n["read_resources"]) + len(n["write_resources"]) for n in nodes),
        },
        "source_side_effect_sites": dict(side_effects),
        "source_side_effects_by_file": by_file,
        "evidence_notes": [
            "Static source evidence, not a runtime measurement.",
            "Package review dependency graph and rehydrate desired-state graph are separate; this graph is src/40-Scoop.ps1.",
            "The package-projections node delegates to a multi-step projection reconciler.",
        ],
    }
    output = json.dumps(result, indent=2, ensure_ascii=False) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output, encoding="utf-8")
    else:
        print(output, end="")


if __name__ == "__main__":
    main()

