/root/.profile: line 11: /workspace/scratch/9406dad8be21/.cargo/env: No such file or directory
#!/usr/bin/env python3
import hashlib
import tempfile
import threading
from pathlib import Path

from blob_store import LocalBlobStore
from generation_prototype import GenerationManager


def test_local_store_round_trip():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        source = root / "source.bin"
        destination = root / "out.bin"
        source.write_bytes(b"capsulenv immutable blob")
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        store = LocalBlobStore(root / "blobs")
        assert not store.has(digest)
        assert store.put(digest, source).size == source.stat().st_size
        assert store.has(digest)
        store.fetch(digest, destination)
        assert destination.read_bytes() == source.read_bytes()


def test_generation_crash_before_activation_keeps_previous():
    with tempfile.TemporaryDirectory() as tmp:
        manager = GenerationManager(tmp)
        old = {"bin/tool.exe": b"old"}
        new = {"bin/tool.exe": b"new"}
        old_id = manager.deploy(old)
        new_id = manager.generation_id(new)
        try:
            manager.realize_publish(new, new_id)
            manager.activate(new_id, crash_after="before-activation")
        except RuntimeError:
            pass
        assert manager.active() == old_id
        assert manager.is_valid(new_id)


def test_generation_crash_after_activation_has_new_valid_authority():
    with tempfile.TemporaryDirectory() as tmp:
        manager = GenerationManager(tmp)
        new = {"bin/tool.exe": b"new"}
        generation = manager.generation_id(new)
        manager.realize_publish(new, generation)
        try:
            manager.activate(generation, crash_after="after-activation")
        except RuntimeError:
            pass
        assert manager.active() == generation


def test_generation_all_publish_activation_boundaries_keep_authority():
    stages = ["realize", "publish", "before-activation", "after-activation"]
    for stage in stages:
        with tempfile.TemporaryDirectory() as tmp:
            manager = GenerationManager(tmp)
            old_id = manager.deploy({"bin/tool.exe": b"old"})
            new = {"bin/tool.exe": b"new"}
            new_id = manager.generation_id(new)
            try:
                manager.realize_publish(new, new_id, crash_after=stage)
                manager.activate(new_id, crash_after=stage)
            except RuntimeError:
                pass
            active = manager.active()
            assert active in {old_id, new_id}, (stage, active)
            assert manager.is_valid(active)


def test_corrupted_active_generation_falls_back_to_previous():
    with tempfile.TemporaryDirectory() as tmp:
        manager = GenerationManager(tmp)
        old_id = manager.deploy({"bin/tool.exe": b"old"})
        new_id = manager.deploy({"bin/tool.exe": b"new"})
        (Path(tmp) / "realizations" / new_id / "bin" / "tool.exe").write_bytes(b"mutated")
        assert manager.active() == old_id


def test_concurrent_threaded_deploy_has_one_valid_authority():
    with tempfile.TemporaryDirectory() as tmp:
        manager = GenerationManager(tmp)
        old_id = manager.deploy({"bin/tool.exe": b"old"})
        results = []

        def deploy(data):
            results.append(manager.deploy({"bin/tool.exe": data}))

        threads = [threading.Thread(target=deploy, args=(b"one",)), threading.Thread(target=deploy, args=(b"two",))]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        assert len(results) == 2
        assert manager.active() in {old_id, *results}
        assert manager.is_valid(manager.active())


if __name__ == "__main__":
    test_local_store_round_trip()
    test_generation_crash_before_activation_keeps_previous()
    test_generation_crash_after_activation_has_new_valid_authority()
    print("prototype tests: PASS")
