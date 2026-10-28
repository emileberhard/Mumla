import datetime as dt
import hashlib
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "dictation-library-backup"
loader = importlib.machinery.SourceFileLoader("dictation_library_backup", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
bk = importlib.util.module_from_spec(spec)
loader.exec_module(bk)

ACCOUNT = "a" * 64
OTHER_ACCOUNT = "b" * 64


def make_export(root: Path, account: str, sid: str, files: dict[str, bytes], complete: bool = True) -> Path:
    export = root / account / sid
    export.mkdir(parents=True)
    for rel, data in files.items():
        path = export / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    manifest = {
        "formatVersion": 1,
        "account": {"hash": account},
        "createdAt": 1_800_000_000,
        "complete": complete,
        "freshness": {"catchUpReachedEnd": complete, **({"lastCatchUpAt": 1_800_000_000} if complete else {})},
        "completeness": {
            "captureCount": 1,
            "resultCount": 1,
            "audioPresentCount": 1 if complete else 0,
            "missingAudioCaptureIDs": [] if complete else ["00000000-0000-0000-0000-000000000001"],
            "problems": [],
        },
        "files": [
            {"path": rel, "byteCount": len(data), "sha256": hashlib.sha256(data).hexdigest()}
            for rel, data in sorted(files.items())
        ],
    }
    (export / "manifest.json").write_text(json.dumps(manifest))
    return export


def sample_files(seed: str = "one") -> dict[str, bytes]:
    return {
        "captures/c1/capture.json": b'{"id":"c1"}',
        "captures/c1/original.caf": os.urandom(300_000) if seed == "random" else (seed.encode() * 70_000),
        "captures/c1/results/r1.json": b"{}",
        "captures/c2/original.caf": b"shared-audio" * 50_000,
        "captures/c2/empty.bin": b"",
    }


@pytest.fixture
def env(tmp_path):
    return {"exports": tmp_path / "exports", "dest": tmp_path / "dest", "tmp": tmp_path}


def run(capsys, *argv: str) -> tuple[int, dict]:
    code = bk.main(list(argv))
    out = capsys.readouterr().out
    return code, json.loads(out)


def backup(capsys, env, export: Path, *extra: str):
    return run(capsys, "backup", "--dest", str(env["dest"]), "--export", str(export), *extra)


def tree_hashes(root: Path) -> dict[str, str]:
    return {
        str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(root.rglob("*"))
        if p.is_file()
    }


def test_snapshot_verify_restore_is_byte_identical(capsys, env):
    export = make_export(env["exports"], ACCOUNT, "20261021T100000Z-aaa", sample_files())
    code, out = backup(capsys, env, export)
    assert code == 0 and out["ok"]
    result = out["results"][0]
    assert result["status"] == "created" and result["files"] == 6 and result["is_latest"]
    assert result["source"]["complete"] is True
    assert result["source"]["freshness"] == {"catchUpReachedEnd": True, "lastCatchUpAt": 1_800_000_000}
    assert result["source"]["completeness"]["problems"] == 0

    code, out = run(capsys, "verify", "--dest", str(env["dest"]))
    assert code == 0 and out["ok"] and out["bad_blobs"] == []

    target = env["tmp"] / "restored"
    code, out = run(capsys, "restore", "--dest", str(env["dest"]), "--account", ACCOUNT, "--target", str(target))
    assert code == 0 and out["snapshot"] == "20261021T100000Z-aaa"
    assert tree_hashes(target) == tree_hashes(export)


def test_duplicate_export_is_idempotent_and_shared_audio_is_deduplicated(capsys, env):
    export = make_export(env["exports"], ACCOUNT, "20261021T100000Z-aaa", sample_files())
    backup(capsys, env, export)
    used = bk.used_bytes(bk.Destination(env["dest"], bk.DEFAULT_BUDGET, 14))
    code, out = backup(capsys, env, export)
    assert code == 0 and out["results"][0]["status"] == "unchanged"
    assert out["results"][0]["new_blob_bytes"] == 0
    assert out["destination"]["used_bytes"] <= used + 8192

    changed = sample_files()
    changed["captures/c3/capture.json"] = b'{"id":"c3"}'
    second = make_export(env["exports"], ACCOUNT, "20261021T110000Z-bbb", changed)
    code, out = backup(capsys, env, second)
    result = out["results"][0]
    assert code == 0 and result["new_blobs"] == 2
    assert result["new_blob_bytes"] < 5000


def test_tampered_blob_is_rejected_by_verify_and_restore_and_backup_repairs_it(capsys, env):
    export = make_export(env["exports"], ACCOUNT, "20261021T100000Z-aaa", sample_files())
    backup(capsys, env, export)
    sha = hashlib.sha256(sample_files()["captures/c2/original.caf"]).hexdigest()
    blob = env["dest"] / "blobs" / sha[:2] / sha
    blob.chmod(0o644)
    data = bytearray(blob.read_bytes())
    data[10] ^= 0xFF
    blob.write_bytes(bytes(data))

    code, out = run(capsys, "verify", "--dest", str(env["dest"]))
    assert code == bk.EXIT["integrity"] and out["bad_blobs"] == [sha]

    target = env["tmp"] / "restored"
    code, out = run(capsys, "restore", "--dest", str(env["dest"]), "--account", ACCOUNT, "--target", str(target))
    assert code == bk.EXIT["integrity"]
    assert not target.exists()

    code, out = backup(capsys, env, export)
    assert code == 0 and out["results"][0]["repaired_blobs"] == 1
    code, out = run(capsys, "verify", "--dest", str(env["dest"]))
    assert code == 0


def test_tampered_snapshot_index_with_traversal_is_rejected(capsys, env):
    export = make_export(env["exports"], ACCOUNT, "20261021T100000Z-aaa", sample_files())
    backup(capsys, env, export)
    index = env["dest"] / "accounts" / ACCOUNT / "snapshots" / "20261021T100000Z-aaa" / "snapshot.json"
    index.chmod(0o644)
    data = json.loads(index.read_text())
    data["files"][0]["path"] = "../../escape.txt"
    index.write_text(json.dumps(data))

    code, _ = run(capsys, "verify", "--dest", str(env["dest"]))
    assert code == bk.EXIT["integrity"]
    target = env["tmp"] / "restored"
    code, _ = run(capsys, "restore", "--dest", str(env["dest"]), "--account", ACCOUNT, "--target", str(target))
    assert code == bk.EXIT["integrity"]
    assert not (env["tmp"] / "escape.txt").exists() and not target.exists()


def test_symlink_in_export_is_rejected_without_leaking_names_or_publishing(capsys, env):
    export = make_export(env["exports"], ACCOUNT, "20261021T100000Z-aaa", sample_files())
    (export / "secret-name.txt").symlink_to("/etc/hosts")
    code, out = backup(capsys, env, export)
    assert code == bk.EXIT["source"] and not out["ok"]
    assert "secret-name" not in json.dumps(out)
    assert list((env["dest"] / "accounts").iterdir()) == []


def test_export_with_files_not_matching_manifest_is_rejected(capsys, env):
    export = make_export(env["exports"], ACCOUNT, "20261021T100000Z-aaa", sample_files())
    (export / "captures/c1/capture.json").write_bytes(b'{"id":"tampered"}')
    code, out = backup(capsys, env, export)
    assert code == bk.EXIT["source"]
    assert list((env["dest"] / "accounts").iterdir()) == []


def test_legacy_shaped_manifest_is_refused_not_misread(capsys, env):
    export = make_export(env["exports"], ACCOUNT, "1800000000-LEGACY", sample_files())
    legacy = {"version": 1, "account": "raw-icloud-id", "completedAt": "2026-10-21T10:00:00Z", "files": []}
    (export / "manifest.json").write_text(json.dumps(legacy))
    code, out = backup(capsys, env, export)
    assert code == bk.EXIT["source"] and "unsupported format version" in out["results"][0]["error"]["message"]
    assert "raw-icloud-id" not in json.dumps(out)


def test_incomplete_export_is_reported_distinctly_and_keeps_last_good(capsys, env):
    good = make_export(env["exports"], ACCOUNT, "20261021T100000Z-aaa", sample_files())
    backup(capsys, env, good)
    bad = make_export(env["exports"], ACCOUNT, "20261021T120000Z-bbb", sample_files("random"), complete=False)
    code, out = backup(capsys, env, bad)
    assert code == bk.EXIT["incomplete"]
    assert out["results"][0]["error"]["source"]["completeness"]["missingAudioCaptureIDs"] == 1

    code, out = run(capsys, "status", "--dest", str(env["dest"]))
    assert out["accounts"][0]["latest"]["snapshot"] == "20261021T100000Z-aaa"


def test_source_mutation_during_copy_publishes_nothing(capsys, env, monkeypatch):
    export = make_export(env["exports"], ACCOUNT, "20261021T100000Z-aaa", sample_files())
    original = bk.stage_blob

    def mutate_then_copy(root, file, sha, stage):
        with open(root / file.rel, "ab") as fh:
            fh.write(b"x")
        return original(root, file, sha, stage)

    monkeypatch.setattr(bk, "stage_blob", mutate_then_copy)
    code, out = backup(capsys, env, export)
    assert code == bk.EXIT["source"]
    assert list((env["dest"] / "accounts").iterdir()) == []
    assert list((env["dest"] / "staging").iterdir()) == []


def test_capacity_failure_preserves_latest_recovery_point(capsys, env):
    first = make_export(env["exports"], ACCOUNT, "20261021T100000Z-aaa", sample_files())
    code, out = backup(capsys, env, first, "--budget-bytes", "1500000")
    assert code == 0
    second = make_export(env["exports"], ACCOUNT, "20261021T110000Z-bbb", sample_files("random"))
    third_files = sample_files("random") | {"captures/c9/original.caf": os.urandom(2_000_000)}
    third = make_export(env["exports"], ACCOUNT, "20261021T120000Z-ccc", third_files)
    code, out = backup(capsys, env, third, "--budget-bytes", "1500000")
    assert code == bk.EXIT["capacity"]
    assert out["results"][0]["error"]["kind"] == "capacity"

    code, out = run(capsys, "status", "--dest", str(env["dest"]), "--budget-bytes", "1500000")
    assert out["accounts"][0]["latest"]["snapshot"] == "20261021T100000Z-aaa"
    target = env["tmp"] / "restored"
    code, _ = run(capsys, "restore", "--dest", str(env["dest"]), "--account", ACCOUNT, "--target", str(target))
    assert code == 0 and tree_hashes(target) == tree_hashes(first)
    assert second.exists()


def test_nonempty_unowned_destination_is_untouched(capsys, env):
    env["dest"].mkdir()
    (env["dest"] / "family-photos.jpg").write_bytes(b"precious")
    before = tree_hashes(env["dest"])
    export = make_export(env["exports"], ACCOUNT, "20261021T100000Z-aaa", sample_files())
    code, out = backup(capsys, env, export)
    assert code == bk.EXIT["destination"]
    assert tree_hashes(env["dest"]) == before and sorted(os.listdir(env["dest"])) == ["family-photos.jpg"]
    code, _ = run(capsys, "verify", "--dest", str(env["dest"]))
    assert code == bk.EXIT["destination"]
    assert sorted(os.listdir(env["dest"])) == ["family-photos.jpg"]


def test_unsupported_destination_format_is_refused(capsys, env):
    export = make_export(env["exports"], ACCOUNT, "20261021T100000Z-aaa", sample_files())
    backup(capsys, env, export)
    marker = env["dest"] / bk.MARKER
    marker.write_text(json.dumps({"format": 2, "kind": bk.MARKER_KIND, "id": "x"}))
    code, out = backup(capsys, env, export)
    assert code == bk.EXIT["destination"] and out["error"]["found"] == 2


def test_retention_keeps_fourteen_daily_points_plus_latest_and_collects_blobs(capsys, env, monkeypatch):
    start = dt.datetime(2026, 9, 1, 12, 0, tzinfo=dt.UTC)
    shas = []
    for day in range(20):
        monkeypatch.setattr(bk, "utcnow", lambda day=day: start + dt.timedelta(days=day))
        files = {"captures/c/original.caf": f"day-{day}".encode() * 1000}
        shas.append(hashlib.sha256(files["captures/c/original.caf"]).hexdigest())
        export = make_export(env["exports"], ACCOUNT, f"20260901T{day:02d}0000Z-x{day}", files)
        code, _ = backup(capsys, env, export)
        assert code == 0
    code, out = run(capsys, "status", "--dest", str(env["dest"]))
    assert out["accounts"][0]["snapshots"] == 14
    assert out["accounts"][0]["latest"]["snapshot"] == "20260901T190000Z-x19"
    blobs = {p.name for p in (env["dest"] / "blobs").rglob("*") if p.is_file()}
    assert shas[19] in blobs and shas[0] not in blobs
    code, _ = run(capsys, "verify", "--dest", str(env["dest"]))
    assert code == 0


def test_each_account_keeps_its_own_latest(capsys, env):
    a = make_export(env["exports"], ACCOUNT, "20261021T100000Z-aaa", sample_files())
    b = make_export(env["exports"], OTHER_ACCOUNT, "20261021T100000Z-bbb", sample_files("random"))
    code, out = run(capsys, "backup", "--dest", str(env["dest"]), "--exports-root", str(env["exports"]))
    assert code == 0 and {r["account"] for r in out["results"]} == {ACCOUNT, OTHER_ACCOUNT}
    code, out = run(capsys, "status", "--dest", str(env["dest"]))
    assert {x["account"]: x["latest"]["snapshot"] for x in out["accounts"]} == {
        ACCOUNT: "20261021T100000Z-aaa",
        OTHER_ACCOUNT: "20261021T100000Z-bbb",
    }
    assert a.exists() and b.exists()


def test_exports_root_ignores_unsealed_staging_and_picks_newest_sealed(capsys, env):
    make_export(env["exports"], ACCOUNT, "20261021T100000Z-old", sample_files())
    make_export(env["exports"], ACCOUNT, "20261021T110000Z-new", sample_files("random"))
    (env["exports"] / ACCOUNT / ".staging-123").mkdir()
    (env["exports"] / ACCOUNT / ".staging-123" / "half.bin").write_bytes(b"partial")
    code, out = run(capsys, "backup", "--dest", str(env["dest"]), "--exports-root", str(env["exports"]))
    assert code == 0 and [r["snapshot"] for r in out["results"]] == ["20261021T110000Z-new"]


def test_interrupted_stage_and_orphan_blobs_are_cleaned_and_not_counted_afterwards(capsys, env):
    export = make_export(env["exports"], ACCOUNT, "20261021T100000Z-aaa", sample_files())
    backup(capsys, env, export)
    (env["dest"] / "staging" / "deadbeef").mkdir()
    (env["dest"] / "staging" / "deadbeef" / "blob-1").write_bytes(b"x" * 100_000)
    orphan = env["dest"] / "blobs" / "ab" / ("ab" * 32)
    orphan.parent.mkdir(exist_ok=True)
    orphan.write_bytes(b"orphan")
    code, out = backup(capsys, env, export)
    assert code == 0 and not orphan.exists()
    assert list((env["dest"] / "staging").iterdir()) == []


def test_restore_refuses_nonempty_target_and_leaves_it_alone(capsys, env):
    export = make_export(env["exports"], ACCOUNT, "20261021T100000Z-aaa", sample_files())
    backup(capsys, env, export)
    target = env["tmp"] / "occupied"
    target.mkdir()
    (target / "mine.txt").write_bytes(b"mine")
    code, _ = run(capsys, "restore", "--dest", str(env["dest"]), "--account", ACCOUNT, "--target", str(target))
    assert code == bk.EXIT["target"]
    assert os.listdir(target) == ["mine.txt"]


def test_second_process_reports_busy(capsys, env):
    export = make_export(env["exports"], ACCOUNT, "20261021T100000Z-aaa", sample_files())
    backup(capsys, env, export)
    dest = bk.Destination(env["dest"], bk.DEFAULT_BUDGET, 14)
    with bk.locked_destination(dest, create=False):
        code, out = backup(capsys, env, export)
    assert code == bk.EXIT["busy"] and out["error"]["kind"] == "busy"


def test_cli_process_contract_reports_json_and_exit_codes(env):
    export = make_export(env["exports"], ACCOUNT, "20261021T100000Z-aaa", sample_files())
    base = [sys.executable, "-I", str(SCRIPT)]
    done = subprocess.run(
        [*base, "backup", "--dest", str(env["dest"]), "--export", str(export)],
        capture_output=True,
        text=True,
    )
    assert done.returncode == 0 and json.loads(done.stdout)["results"][0]["status"] == "created"
    bad = subprocess.run([*base, "restore", "--dest", str(env["dest"])], capture_output=True, text=True)
    assert bad.returncode == 2 and json.loads(bad.stdout)["error"]["kind"] == "usage"
