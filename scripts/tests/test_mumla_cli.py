import importlib.machinery
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

import pytest


@pytest.fixture
def cli():
    loader = importlib.machinery.SourceFileLoader(
        "mumla_cli", str(Path(__file__).parents[1] / "mumla")
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def test_private_request_round_trip_and_result_readback(
    cli, monkeypatch, tmp_path, capsys
):
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    requests = []

    def wake(args, identifier):
        folder = tmp_path / cli.RELATIVE_ROOT / identifier
        request = json.loads((folder / "request.json").read_text())
        requests.append(request)
        assert request["operation"] == "legacy-reconcile"
        assert request["accountHash"] == "a" * 64
        assert (folder.stat().st_mode & 0o777) == 0o700
        (folder / "response.json").write_text(
            json.dumps(
                {
                    "formatVersion": 1,
                    "requestID": identifier,
                    "ok": True,
                    "data": {"remaining": 0},
                }
            )
        )

    monkeypatch.setattr(cli, "wake", wake)
    assert cli.main(["legacy", "reconcile", "--account", "a" * 64]) == 0
    response = json.loads(capsys.readouterr().out)
    assert response["data"] == {"remaining": 0}
    assert cli.main(["result", response["requestID"]]) == 0
    assert json.loads(capsys.readouterr().out) == response
    assert len(requests) == 1


def test_pending_result_does_not_repeat_operation(cli, monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setattr(
        cli, "wake", lambda *args: pytest.fail("result must not launch an operation")
    )
    assert cli.main(["result", "CC95661D-8B54-4052-9B1B-E0D351D1700F"]) == 3
    assert json.loads(capsys.readouterr().out)["error"]["code"] == "pending"


def test_audio_integrity_failure_never_publishes_output(cli, tmp_path):
    original = tmp_path / "source"
    original.write_bytes(b"damaged")
    output = tmp_path / "export.caf"
    temporary = tmp_path / "temporary"
    temporary.mkdir()
    args = SimpleNamespace(output=output, device=None)
    response = {"data": {"path": str(original), "byteCount": 7, "sha256": "a" * 64}}
    with pytest.raises(cli.Failure, match="checksum"):
        cli.export_audio(args, response, temporary)
    assert not output.exists()


def test_only_missing_device_file_is_pending(cli, monkeypatch):
    def run(args, **kwargs):
        receipt = Path(args[args.index("--json-output") + 1])
        receipt.write_text(
            json.dumps(
                {"error": {"domain": "com.apple.dt.CoreDeviceError", "code": 7000}}
            )
        )
        return SimpleNamespace(returncode=1)

    monkeypatch.setattr(cli.subprocess, "run", run)
    with pytest.raises(cli.Failure) as error:
        cli.device_command("synthetic", ["copy", "from"])
    assert error.value.code == "missingFile"

    def disconnected(args, **kwargs):
        return SimpleNamespace(returncode=1)

    monkeypatch.setattr(cli.subprocess, "run", disconnected)
    with pytest.raises(cli.Failure) as error:
        cli.device_command("synthetic", ["copy", "from"])
    assert error.value.code == "transport"


def test_device_selector_precedes_variadic_app_arguments(cli, monkeypatch):
    commands = []

    def run(args, **kwargs):
        commands.append(args)
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(cli.subprocess, "run", run)
    cli.wake(
        SimpleNamespace(device="synthetic-phone"),
        "CC95661D-8B54-4052-9B1B-E0D351D1700F",
    )
    args = commands[0]
    assert args.index("--device") < args.index(cli.BUNDLE)
    assert args[args.index("--device") + 1] == "synthetic-phone"
    assert "--no-activate" not in args
    assert "--terminate-existing" not in args


def test_polling_failure_preserves_dispatched_request_identity(
    cli, monkeypatch, tmp_path
):
    identifier = "CC95661D-8B54-4052-9B1B-E0D351D1700F"
    monkeypatch.setattr(cli, "wake", lambda *args: None)

    def disconnected(*args):
        raise cli.Failure("transport", "Device disconnected")

    monkeypatch.setattr(cli, "read_response", disconnected)
    with pytest.raises(cli.Failure) as failure:
        cli.dispatch_and_wait(
            SimpleNamespace(timeout=5, device="synthetic"), identifier, tmp_path
        )
    assert failure.value.code == "outcomeUncertain"
    assert failure.value.request_id == identifier
    assert "before retrying" in str(failure.value)
