#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.14"
# dependencies = ["google-genai"]
# ///
"""Generate the realtime-transcription evaluation fixtures with Gemini TTS."""

import argparse
import base64
import concurrent.futures
import random
import tempfile
import time
import wave
from pathlib import Path

import google.genai as genai

from evaluation_support import (
    GOOGLE_VIA_ROUTER,
    Fixture,
    load_fixtures,
    router_key,
    select_fixtures,
)


EVALUATION_DIR = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = EVALUATION_DIR / "fixtures" / "manifest.json"
MODEL = "gemini-3.1-flash-tts-preview"
PREAMBLE = "Synthesize speech for the following dictation. Only the TRANSCRIPT section is spoken aloud."
PACING = {
    "en": (
        "Pacing: Unhurried. At every [pauses] leave roughly one second of true "
        "silence; at every [long pause] leave two to three seconds of true "
        "silence while thinking. Stretch hesitation sounds like um and uh "
        "naturally. Do not fill the pauses with sound."
    ),
    "sv": (
        "Pacing: Unhurried. At every [pauses] leave roughly one second of true "
        "silence; at every [long pause] leave two to three seconds of true "
        "silence while thinking. Stretch hesitation sounds like eh and öh "
        "naturally. Do not fill the pauses with sound. Speak natural colloquial Swedish."
    ),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument(
        "--output", type=Path, help="WAV directory; defaults to the manifest directory"
    )
    parser.add_argument(
        "--fixtures", default="", help="comma-separated fixture ids; defaults to all"
    )
    parser.add_argument(
        "--replace", action="store_true", help="regenerate existing selected WAV files"
    )
    parser.add_argument("--attempts", type=int, default=4, help="attempts per fixture")
    parser.add_argument(
        "--workers",
        type=int,
        default=0,
        help="parallel requests; 0 means one per pending fixture",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="show fixture status without generating audio",
    )
    return parser.parse_args()


def synthesis_prompt(fixture: Fixture) -> str:
    pacing = (
        PACING[fixture.language]
        if "[pauses]" in fixture.transcript or "[long pause]" in fixture.transcript
        else ""
    )
    return "\n\n".join(
        [
            PREAMBLE,
            f"# AUDIO PROFILE\n{fixture.profile}",
            f"## THE SCENE\n{fixture.scene}",
            (
                "### DIRECTOR'S NOTES\n"
                f"Style: {fixture.style}\n"
                f"{pacing}\n"
                f"Total length should be {fixture.target}."
            ),
            f"#### TRANSCRIPT\n{fixture.transcript}",
        ]
    )


def write_wav_atomic(path: Path, pcm: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        prefix=f".{path.name}.", dir=path.parent, delete=False
    ) as temporary:
        temporary_path = Path(temporary.name)
    try:
        with wave.open(str(temporary_path), "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(24_000)
            wav.writeframes(pcm)
        temporary_path.replace(path)
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise


def generate_fixture(
    fixture: Fixture, output_dir: Path, api_key: str, attempts: int
) -> str:
    client = genai.Client(api_key=api_key, http_options={"base_url": GOOGLE_VIA_ROUTER})
    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            interaction = client.interactions.create(
                model=MODEL,
                input=synthesis_prompt(fixture),
                response_format={"type": "audio"},
                generation_config={"speech_config": [{"voice": fixture.voice}]},
            )
            audio = interaction.output_audio
            if audio is None or audio.data is None:
                raise RuntimeError("provider response did not contain audio data")
            pcm = base64.b64decode(audio.data, validate=True)
            if not pcm:
                raise RuntimeError("provider returned empty audio")
            write_wav_atomic(output_dir / fixture.file, pcm)
            return f"{fixture.id}: {len(pcm) / 48_000:.1f} s ({fixture.voice})"
        except Exception as error:  # Provider failures are retried at this boundary.
            last_error = error
            if attempt < attempts:
                time.sleep(min(8, 2 ** (attempt - 1)) + random.uniform(0, 0.5))
    raise RuntimeError(f"{fixture.id} failed after {attempts} attempts: {last_error}")


def main() -> None:
    args = parse_args()
    if args.attempts < 1 or args.workers < 0:
        raise SystemExit("--attempts must be positive and --workers cannot be negative")

    manifest_path = args.manifest.resolve()
    fixtures = select_fixtures(load_fixtures(manifest_path), args.fixtures)
    output_dir = args.output.resolve() if args.output else manifest_path.parent

    if args.list:
        for fixture in fixtures:
            status = "present" if (output_dir / fixture.file).is_file() else "missing"
            print(f"{fixture.id}: {status}")
        return

    pending = [
        fixture
        for fixture in fixtures
        if args.replace or not (output_dir / fixture.file).is_file()
    ]
    skipped = len(fixtures) - len(pending)
    if not pending:
        print(f"all {len(fixtures)} selected fixtures already exist")
        return

    api_key = router_key()

    workers = args.workers or len(pending)
    print(
        f"generating {len(pending)} fixtures with {workers} parallel requests; {skipped} existing skipped"
    )
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [
            pool.submit(generate_fixture, fixture, output_dir, api_key, args.attempts)
            for fixture in pending
        ]
        for future in concurrent.futures.as_completed(futures):
            print(future.result())


if __name__ == "__main__":
    main()
