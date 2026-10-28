import importlib.machinery
import importlib.util
import plistlib
import subprocess
from pathlib import Path

import pytest

loader = importlib.machinery.SourceFileLoader("sign_bundles", str(Path(__file__).resolve().parents[1] / "sign-bundles"))
spec = importlib.util.spec_from_loader(loader.name, loader)
signing = importlib.util.module_from_spec(spec)
loader.exec_module(signing)


@pytest.mark.parametrize(("channel", "authority"), [("ios", "Apple Distribution"), ("macos", "Apple Distribution"), ("developer-id", "Developer ID Application")])
@pytest.mark.parametrize("valid", [True, False])
def test_exported_framework_authority_including_nested_extensions(tmp_path, monkeypatch, channel, authority, valid):
    app = tmp_path / "App.app"
    nested = app / "PlugIns/MumlaKeyboard.appex" if channel == "ios" else app / "Contents"
    framework = nested / "Frameworks/SDK.framework"
    framework.mkdir(parents=True)
    monkeypatch.setenv("APP_BUNDLE_ID", "emileberhard.WisprClone.ios")
    monkeypatch.setenv("DEVELOPMENT_TEAM", "NNP2B278S6")

    def codesign(args, **kwargs):
        if args[1] == "-dvv":
            signature = f"Authority={authority}: Example (NNP2B278S6)\nflags=0x10000(runtime)" if valid else "Signature=adhoc\nflags=0x20002(adhoc,linker-signed)"
            return subprocess.CompletedProcess(args, 0, b"", signature.encode())
        source = signing.ROOT / ("ios/MumlaKeyboard/MumlaKeyboard.entitlements" if Path(args[-1]).suffix == ".appex" else {
            "ios": "ios/MumlaiOS/MumlaiOS.entitlements",
            "macos": "Mumla/Mumla.entitlements",
            "developer-id": "Mumla/MumlaDeveloperID.entitlements",
        }[channel])
        text = source.read_text().replace("$(TeamIdentifierPrefix)", "NNP2B278S6.")
        return subprocess.CompletedProcess(args, 0, plistlib.dumps(plistlib.loads(text.encode())), b"")

    monkeypatch.setattr(signing.subprocess, "run", codesign)
    if valid:
        signing.main("check", app, channel)
    else:
        with pytest.raises(SystemExit, match=f"SDK.framework.*{authority}"):
            signing.main("check", app, channel)


def test_developer_id_export_requires_the_hardened_runtime(tmp_path, monkeypatch):
    app = tmp_path / "Mumla.app"
    app.mkdir()
    monkeypatch.setenv("APP_BUNDLE_ID", "emileberhard.WisprClone")
    monkeypatch.setenv("DEVELOPMENT_TEAM", "NNP2B278S6")

    def codesign(args, **kwargs):
        if args[1] == "-dvv":
            return subprocess.CompletedProcess(args, 0, b"", b"Authority=Developer ID Application: Example (NNP2B278S6)\nflags=0x0(none)")
        text = (signing.ROOT / "Mumla/MumlaDeveloperID.entitlements").read_text().replace("$(TeamIdentifierPrefix)", "NNP2B278S6.")
        return subprocess.CompletedProcess(args, 0, plistlib.dumps(plistlib.loads(text.encode())), b"")

    monkeypatch.setattr(signing.subprocess, "run", codesign)
    with pytest.raises(SystemExit, match="hardened runtime"):
        signing.main("check", app, "developer-id")
