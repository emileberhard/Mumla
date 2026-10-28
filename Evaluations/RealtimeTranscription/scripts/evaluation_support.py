import json
import os
import re
import tempfile
from dataclasses import dataclass
from pathlib import Path

ROUTER_ORIGIN = os.environ.get("LLM_ROUTER_ORIGIN", "")
ROUTER_KEY_FILE = Path.home() / ".config" / "llm-router" / "key"
GOOGLE_ORIGIN = "https://generativelanguage.googleapis.com"
GOOGLE_VIA_ROUTER = f"{ROUTER_ORIGIN}/vendors/google"


def router_key() -> str:
    if not ROUTER_ORIGIN.startswith("https://"):
        raise SystemExit("Set LLM_ROUTER_ORIGIN to the router's HTTPS origin")
    try:
        key = ROUTER_KEY_FILE.read_text().strip()
    except FileNotFoundError:
        key = ""
    if not key:
        raise SystemExit(
            f"Install this device's llm-router key at {ROUTER_KEY_FILE}"
        )
    return key


@dataclass(frozen=True)
class Fixture:
    id: str
    file: str
    language: str
    voice: str
    target: str
    profile: str
    scene: str
    style: str
    transcript: str

    def audio_path(self, manifest_path: Path) -> Path:
        return manifest_path.parent / self.file

    @property
    def reference(self) -> str:
        return re.sub(r"\[[^\]]*\]\s*", "", self.transcript).strip()


def load_fixtures(manifest_path: Path) -> list[Fixture]:
    raw = json.loads(manifest_path.read_text())
    if not isinstance(raw, list) or not raw:
        raise ValueError("fixture manifest must be a non-empty JSON array")

    fixtures: list[Fixture] = []
    field_names = set(Fixture.__dataclass_fields__)
    for index, raw_entry in enumerate(raw):
        if not isinstance(raw_entry, dict) or not all(
            isinstance(key, str) for key in raw_entry
        ):
            raise ValueError(f"fixture {index} must be an object")
        entry: dict[str, object] = {
            key: value for key, value in raw_entry.items() if isinstance(key, str)
        }
        if set(entry) != field_names:
            missing = field_names - entry.keys()
            extra = entry.keys() - field_names
            details = []
            if missing:
                details.append(f"missing {', '.join(sorted(missing))}")
            if extra:
                details.append(f"unknown {', '.join(sorted(extra))}")
            raise ValueError(
                f"fixture {index} has invalid fields: {'; '.join(details)}"
            )
        if not all(isinstance(value, str) for value in entry.values()):
            raise ValueError(f"fixture {index} fields must all be strings")
        fixture = Fixture(
            id=str(entry["id"]),
            file=str(entry["file"]),
            language=str(entry["language"]),
            voice=str(entry["voice"]),
            target=str(entry["target"]),
            profile=str(entry["profile"]),
            scene=str(entry["scene"]),
            style=str(entry["style"]),
            transcript=str(entry["transcript"]),
        )
        if not fixture.id or not fixture.reference:
            raise ValueError(f"fixture {index} must have a non-empty id and transcript")
        if fixture.language not in {"en", "sv"}:
            raise ValueError(
                f"fixture {fixture.id} has unsupported language {fixture.language!r}"
            )
        if Path(fixture.file).name != fixture.file or not fixture.file.endswith(".wav"):
            raise ValueError(f"fixture {fixture.id} must use a local .wav filename")
        fixtures.append(fixture)

    for label, values in {
        "id": [fixture.id for fixture in fixtures],
        "filename": [fixture.file for fixture in fixtures],
    }.items():
        if len(values) != len(set(values)):
            raise ValueError(f"fixture {label}s must be unique")
    return fixtures


def select_fixtures(fixtures: list[Fixture], requested: str) -> list[Fixture]:
    if not requested:
        return fixtures
    wanted = {value.strip() for value in requested.split(",") if value.strip()}
    known = {fixture.id for fixture in fixtures}
    unknown = wanted - known
    if unknown:
        raise ValueError(f"unknown fixture ids: {', '.join(sorted(unknown))}")
    return [fixture for fixture in fixtures if fixture.id in wanted]


def write_text_atomic(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", dir=path.parent
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w") as temporary_file:
            temporary_file.write(content)
        temporary_path.replace(path)
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise
