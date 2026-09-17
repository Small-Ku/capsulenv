#!/usr/bin/env python3
"""Thin immutable blob-store prototype for architecture experiments."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


@dataclass(frozen=True)
class BlobStat:
    digest: str
    size: int


class LocalBlobStore:
    """Filesystem implementation; identity is the verified digest, not a path."""

    def __init__(self, root: str | Path):
        self.root = Path(root)

    def _path(self, digest: str) -> Path:
        if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest.lower()):
            raise ValueError("digest must be a lowercase/uppercase SHA-256 hex string")
        return self.root / digest[:2] / digest

    def has(self, digest: str) -> bool:
        return self._path(digest).is_file()

    def stat(self, digest: str) -> BlobStat:
        path = self._path(digest)
        if not path.is_file():
            raise FileNotFoundError(digest)
        actual = sha256_file(path)
        if actual != digest.lower():
            raise ValueError(f"blob identity mismatch: expected {digest}, got {actual}")
        return BlobStat(digest=actual, size=path.stat().st_size)

    def put(self, digest: str, source: str | Path) -> BlobStat:
        source = Path(source)
        actual = sha256_file(source)
        if actual != digest.lower():
            raise ValueError(f"source hash mismatch: expected {digest}, got {actual}")
        target = self._path(digest.lower())
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            return self.stat(digest)
        temporary = target.with_name(target.name + f".{os.getpid()}.partial")
        shutil.copyfile(source, temporary)
        if sha256_file(temporary) != digest.lower():
            temporary.unlink(missing_ok=True)
            raise ValueError("blob changed during put")
        os.replace(temporary, target)
        return self.stat(digest)

    def fetch(self, digest: str, destination: str | Path) -> BlobStat:
        stat = self.stat(digest)
        destination = Path(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(destination.name + f".{os.getpid()}.partial")
        shutil.copyfile(self._path(digest), temporary)
        if sha256_file(temporary) != digest.lower():
            temporary.unlink(missing_ok=True)
            raise ValueError("blob changed during fetch")
        os.replace(temporary, destination)
        return stat


class RcloneBlobStore:
    """Transport adapter only; generation and activation remain local authority."""

    def __init__(self, remote_root: str, rclone: str = "rclone"):
        self.remote_root = remote_root.rstrip("/")
        self.rclone = rclone

    def _remote(self, digest: str) -> str:
        if len(digest) != 64:
            raise ValueError("invalid digest")
        return f"{self.remote_root}/{digest[:2]}/{digest}"

    def _run(self, *args: str):
        return subprocess.run([self.rclone, *args], check=True, capture_output=True, text=True)

    def has(self, digest: str) -> bool:
        result = subprocess.run([self.rclone, "size", self._remote(digest)], capture_output=True, text=True)
        return result.returncode == 0

    def stat(self, digest: str) -> BlobStat:
        result = self._run("size", self._remote(digest), "--json")
        payload = json.loads(result.stdout)
        return BlobStat(digest=digest.lower(), size=int(payload["bytes"]))

    def put(self, digest: str, source: str | Path) -> BlobStat:
        if sha256_file(Path(source)) != digest.lower():
            raise ValueError("source hash mismatch")
        self._run("copyto", str(source), self._remote(digest.lower()))
        return self.stat(digest)

    def fetch(self, digest: str, destination: str | Path) -> BlobStat:
        destination = Path(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        self._run("copyto", self._remote(digest.lower()), str(destination))
        if sha256_file(destination) != digest.lower():
            raise ValueError("remote fetch hash mismatch")
        return self.stat(digest)

