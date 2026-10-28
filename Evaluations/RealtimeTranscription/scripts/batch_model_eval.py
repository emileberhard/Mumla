#!/usr/bin/env python3
"""Measure batch (non-realtime) transcription models against the fixture corpus.

Realtime providers are covered by run_evaluation.py. This runner targets the
batch models that matter for ambient background transcription, where round-trip
latency is irrelevant and cost per audio hour dominates.

Scoring reuses run_evaluation.py and Fixture.reference, so the numbers are
directly comparable to the realtime runs.
"""

from __future__ import annotations

import argparse
import base64
import concurrent.futures
import json
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import wave
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from evaluation_support import (
    GOOGLE_ORIGIN,
    GOOGLE_VIA_ROUTER,
    load_fixtures,
    router_key,
    write_text_atomic,
)
from run_evaluation import normalized_words, without_fillers, word_error_rate

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures"
RESULTS = Path(__file__).resolve().parent.parent / "results" / "batch-models"
ENDPOINT = GOOGLE_VIA_ROUTER + "/v1beta/models/{model}:generateContent"
FILES_ENDPOINT = GOOGLE_VIA_ROUTER + "/upload/v1beta/files"
INTERACTIONS_ENDPOINT = GOOGLE_VIA_ROUTER + "/v1beta/interactions"
TRANSCRIBE_MODEL = "gemini-3.5-transcribe"

# Verbatim-preserving instruction. Identical for every model so the comparison
# measures the model, not the prompt.
PROMPT = (
    "Transcribe this audio verbatim. Write exactly what is said, including "
    "filler words such as um, uh, eh and öh. Do not translate, summarize, "
    "correct, or clean up the speech. Do not describe non-speech sounds. "
    "Output only the transcript text."
)

# Published rates checked August 2026. Audio input is not itemized
# separately for 3.5/3.6 Flash on the pricing page; the unified input rate is
# used and flagged as such in the report.
PRICING = {
    TRANSCRIBE_MODEL: {"fixed_per_audio_hour": 0.30},
    "gemini-3.5-flash": {"input": 1.50, "output": 9.00, "audio_itemized": False},
    "gemini-3.6-flash": {"input": 1.50, "output": 7.50, "audio_itemized": False},
    "gemini-3.5-flash-lite": {"input": 0.30, "output": 2.50, "audio_itemized": True},
}

LANGUAGE_CODES = {"en": "en-US", "sv": "sv-SE"}


def duration_seconds(path: Path) -> float:
    with wave.open(str(path)) as handle:
        return handle.getnframes() / handle.getframerate()


def score(reference: str, hypothesis: str) -> dict[str, float]:
    """Score exactly as run_evaluation.py does, against Fixture.reference."""
    reference_words = normalized_words(reference)
    hypothesis_words = normalized_words(hypothesis)
    if not hypothesis_words:
        return {"wer": 1.0, "wer_nf": 1.0}
    return {
        "wer": round(word_error_rate(reference_words, hypothesis_words), 4),
        "wer_nf": round(
            word_error_rate(
                without_fillers(reference_words), without_fillers(hypothesis_words)
            ),
            4,
        ),
    }


def request_json(request: urllib.request.Request, timeout: int = 300) -> dict[str, Any]:
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def transcribe_dedicated(audio: Path, language: str, api_key: str) -> dict[str, Any]:
    started = time.monotonic()
    audio_data = audio.read_bytes()
    headers = {
        "Content-Type": "application/json",
        "X-Goog-Upload-Protocol": "resumable",
        "X-Goog-Upload-Command": "start",
        "X-Goog-Upload-Header-Content-Length": str(len(audio_data)),
        "X-Goog-Upload-Header-Content-Type": "audio/wav",
        "x-goog-api-key": api_key,
    }
    start_request = urllib.request.Request(
        FILES_ENDPOINT,
        data=json.dumps({"file": {"display_name": audio.name}}).encode(),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(start_request, timeout=300) as response:
        upload_url = response.headers.get("X-Goog-Upload-URL")
    if not upload_url:
        raise RuntimeError("Gemini Files API did not return an upload URL")

    upload_request = urllib.request.Request(
        upload_url.replace(GOOGLE_ORIGIN, GOOGLE_VIA_ROUTER, 1),
        data=audio_data,
        headers={
            "Content-Length": str(len(audio_data)),
            "X-Goog-Upload-Offset": "0",
            "X-Goog-Upload-Command": "upload, finalize",
            "x-goog-api-key": api_key,
        },
        method="POST",
    )
    uploaded = request_json(upload_request)
    file = uploaded.get("file") or {}
    file_name = file.get("name", "")
    file_uri = file.get("uri", "")
    if not file_name or not file_uri:
        raise RuntimeError("Gemini Files API returned an invalid file")

    interaction_payload = {
        "model": TRANSCRIBE_MODEL,
        "input": [{"type": "audio", "uri": file_uri, "mime_type": "audio/wav"}],
        "generation_config": {
            "transcription_config": {
                "language_codes": [LANGUAGE_CODES[language]],
                "custom_vocabulary": [],
                "mode": {"type": "smart"},
            }
        },
        "store": False,
    }
    try:
        interaction_request = urllib.request.Request(
            INTERACTIONS_ENDPOINT,
            data=json.dumps(interaction_payload).encode(),
            headers={"Content-Type": "application/json", "x-goog-api-key": api_key},
            method="POST",
        )
        body = request_json(interaction_request)
    finally:
        file_id = urllib.parse.quote(file_name.rsplit("/", 1)[-1], safe="")
        delete_request = urllib.request.Request(
            f"{GOOGLE_VIA_ROUTER}/v1beta/files/{file_id}",
            headers={"x-goog-api-key": api_key},
            method="DELETE",
        )
        try:
            urllib.request.urlopen(delete_request, timeout=300).close()
        except urllib.error.URLError:
            pass
    elapsed = time.monotonic() - started

    transcript = (body.get("output_text") or "").strip()
    if not transcript:
        outputs = body.get("outputs")
        if outputs is None:
            outputs = [
                content
                for step in body.get("steps", [])
                for content in step.get("content", [])
            ]
        transcript = "".join(
            output.get("text", "")
            for output in outputs or []
            if output.get("type") in (None, "text")
        ).strip()
    if not transcript:
        raise RuntimeError("Gemini Transcribe returned an empty transcript")
    return {
        "transcript": transcript,
        "round_trip_s": round(elapsed, 2),
        "usage": body.get("usage_metadata", body.get("usageMetadata", {})),
    }


def transcribe(
    model: str, audio: Path, language: str, api_key: str, thinking: bool
) -> dict[str, Any]:
    if model == TRANSCRIBE_MODEL:
        return transcribe_dedicated(audio, language, api_key)

    generation: dict[str, Any] = {"temperature": 0.0}
    if not thinking:
        # Thinking tokens bill at the output rate and dominate transcription
        # cost at the default level. Gemini 3.x cannot disable thinking; the
        # floor is thinking_level "minimal".
        generation["thinkingConfig"] = {"thinkingLevel": "MINIMAL"}
    payload = {
        "contents": [
            {
                "parts": [
                    {"text": PROMPT},
                    {
                        "inline_data": {
                            "mime_type": "audio/wav",
                            "data": base64.b64encode(audio.read_bytes()).decode(),
                        }
                    },
                ]
            }
        ],
        "generationConfig": generation,
    }
    request = urllib.request.Request(
        ENDPOINT.format(model=model),
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "x-goog-api-key": api_key},
    )
    started = time.monotonic()
    with urllib.request.urlopen(request, timeout=300) as response:
        body = json.load(response)
    elapsed = time.monotonic() - started

    candidates = body.get("candidates") or []
    parts = candidates[0].get("content", {}).get("parts", []) if candidates else []
    transcript = "".join(part.get("text", "") for part in parts).strip()
    if not transcript:
        raise RuntimeError(
            f"empty transcript (finishReason={candidates[0].get('finishReason') if candidates else 'none'})"
        )
    return {
        "transcript": transcript,
        "round_trip_s": round(elapsed, 2),
        "usage": body.get("usageMetadata", {}),
    }


def run_one(
    model: str, fixture: Any, repetition: int, api_key: str, rerun: bool, thinking: bool
) -> dict[str, Any]:
    variant = model if thinking else f"{model}-nothink"
    log = RESULTS / variant / f"{fixture.id}-run{repetition}.json"
    if log.exists() and not rerun:
        return json.loads(log.read_text())

    audio = FIXTURES / fixture.file
    record: dict[str, Any] = {
        "model": model,
        "variant": variant,
        "thinking": thinking if model != TRANSCRIBE_MODEL else False,
        "fixture": fixture.id,
        "language": fixture.language,
        "repetition": repetition,
        "audio_seconds": round(duration_seconds(audio), 2),
    }
    try:
        result = transcribe(model, audio, fixture.language, api_key, thinking)
    except (
        urllib.error.HTTPError,
        urllib.error.URLError,
        RuntimeError,
        TimeoutError,
    ) as error:
        detail = ""
        if isinstance(error, urllib.error.HTTPError):
            detail = error.read().decode(errors="replace")[:400]
        record["failure"] = f"{type(error).__name__}: {error} {detail}".strip()
    else:
        record.update(result)
        record.update(score(fixture.reference, result["transcript"]))

    log.parent.mkdir(parents=True, exist_ok=True)
    write_text_atomic(log, json.dumps(record, ensure_ascii=False, indent=2))
    return record


def audio_tokens(usage: dict[str, Any]) -> int:
    for detail in usage.get("promptTokensDetails", []):
        if detail.get("modality") == "AUDIO":
            return int(detail.get("tokenCount", 0))
    return 0


def cost_per_audio_hour(model: str, records: list[dict[str, Any]]) -> float | None:
    rates = PRICING.get(model)
    if rates and "fixed_per_audio_hour" in rates:
        return rates["fixed_per_audio_hour"]
    usable = [r for r in records if r.get("usage") and r.get("audio_seconds")]
    if not rates or not usable:
        return None
    seconds = sum(r["audio_seconds"] for r in usable)
    prompt = sum(int(r["usage"].get("promptTokenCount", 0)) for r in usable)
    output = sum(
        int(r["usage"].get("candidatesTokenCount", 0))
        + int(r["usage"].get("thoughtsTokenCount", 0))
        for r in usable
    )
    cost = (prompt * rates["input"] + output * rates["output"]) / 1_000_000
    return round(cost / (seconds / 3600), 4)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--models",
        default="gemini-3.6-flash,gemini-3.5-flash-lite,gemini-3.5-flash",
        help="comma-separated Gemini model IDs",
    )
    parser.add_argument(
        "--min-duration",
        type=float,
        default=24.0,
        help="skip fixtures shorter than this many seconds",
    )
    parser.add_argument("--runs", type=int, default=3, help="repetitions per fixture")
    parser.add_argument("--concurrency", type=int, default=8)
    parser.add_argument("--rerun", action="store_true", help="ignore completed logs")
    parser.add_argument("--plan", action="store_true", help="print the plan and exit")
    parser.add_argument(
        "--no-thinking",
        action="store_true",
        help="set thinkingBudget=0; thinking tokens bill at the output rate",
    )
    arguments = parser.parse_args()

    api_key = router_key()

    models = [m.strip() for m in arguments.models.split(",") if m.strip()]
    fixtures = [
        fixture
        for fixture in load_fixtures(FIXTURES / "manifest.json")
        if duration_seconds(FIXTURES / fixture.file) >= arguments.min_duration
    ]
    fixtures.sort(key=lambda f: f.id)
    if not fixtures:
        print(f"no fixtures at or above {arguments.min_duration}s", file=sys.stderr)
        return 1

    total = len(models) * len(fixtures) * arguments.runs
    seconds = sum(duration_seconds(FIXTURES / f.file) for f in fixtures)
    print(
        f"{total} runs: {len(models)} models x {len(fixtures)} fixtures "
        f"x {arguments.runs} repetitions ({seconds:.0f}s audio per model-pass)"
    )
    for fixture in fixtures:
        print(
            f"  {fixture.id} ({fixture.language}, "
            f"{duration_seconds(FIXTURES / fixture.file):.0f}s)"
        )
    if arguments.plan:
        return 0

    work = [
        (model, fixture, repetition)
        for model in models
        for fixture in fixtures
        for repetition in range(1, arguments.runs + 1)
    ]
    records: list[dict[str, Any]] = []
    with concurrent.futures.ThreadPoolExecutor(
        max_workers=arguments.concurrency
    ) as pool:
        futures = {
            pool.submit(
                run_one,
                model,
                fixture,
                repetition,
                api_key,
                arguments.rerun,
                not arguments.no_thinking,
            ): (
                model,
                fixture.id,
            )
            for model, fixture, repetition in work
        }
        for index, future in enumerate(
            concurrent.futures.as_completed(futures), start=1
        ):
            model, fixture_id = futures[future]
            record = future.result()
            records.append(record)
            status = "FAIL" if "failure" in record else f"{record['wer_nf']:.1%}"
            print(f"[{index}/{total}] {model} {fixture_id}: {status}", flush=True)

    write_report(records, models, arguments)
    return 0


def write_report(
    records: list[dict[str, Any]], models: list[str], arguments: argparse.Namespace
) -> None:
    RESULTS.mkdir(parents=True, exist_ok=True)
    suffix = "-nothink" if arguments.no_thinking else ""
    write_text_atomic(
        RESULTS / f"summary{suffix}.json",
        json.dumps(records, ensure_ascii=False, indent=2),
    )

    mode_notes = []
    if TRANSCRIBE_MODEL in models:
        mode_notes.append("Gemini 3.5 Transcribe uses smart transcription mode.")
    if any(model != TRANSCRIBE_MODEL for model in models):
        thinking = "minimal" if arguments.no_thinking else "enabled"
        mode_notes.append(f"Generative-model thinking is {thinking}.")

    lines = [
        "# Batch model evaluation",
        "",
        f"Fixtures at or above {arguments.min_duration:.0f}s, "
        f"{arguments.runs} repetitions per fixture. " + " ".join(mode_notes),
        "",
        (
            "`WER-nf` is filler-normalized word error rate, scored identically to "
            "run_evaluation.py against `Fixture.reference`."
        ),
        "",
        "| Model | EN WER-nf | SV WER-nf | overall WER-nf | round-trip | $/audio hr |",
        "|---|---|---|---|---|---|",
    ]
    for model in models:
        rows = [r for r in records if r["model"] == model and "failure" not in r]
        if not rows:
            lines.append(f"| {model} | — | — | — | — | failed |")
            continue

        def mean(subset: list[dict[str, Any]], key: str) -> float | None:
            values = [r[key] for r in subset if key in r]
            return statistics.mean(values) if values else None

        english = [r for r in rows if r["language"] == "en"]
        swedish = [r for r in rows if r["language"] == "sv"]
        cost = cost_per_audio_hour(model, rows)
        lines.append(
            "| {model} | {en} | {sv} | {all_} | {rt:.1f} s | {cost} |".format(
                model=model,
                en=f"{mean(english, 'wer_nf'):.1%}" if english else "—",
                sv=f"{mean(swedish, 'wer_nf'):.1%}" if swedish else "—",
                all_=f"{mean(rows, 'wer_nf'):.1%}",
                rt=mean(rows, "round_trip_s") or 0.0,
                cost=f"${cost:.3f}" if cost is not None else "—",
            )
        )

    failures = [r for r in records if "failure" in r]
    if failures:
        lines += ["", f"## Failures ({len(failures)})", ""]
        for record in failures:
            lines.append(
                f"- `{record['model']}` / `{record['fixture']}` "
                f"run {record['repetition']}: {record['failure'][:200]}"
            )

    lines += [
        "",
        "## Per-fixture WER-nf",
        "",
        "| Fixture | lang | " + " | ".join(models) + " |",
        "|---|---|" + "---|" * len(models),
    ]
    fixture_ids = sorted({r["fixture"] for r in records})
    for fixture_id in fixture_ids:
        language = next(r["language"] for r in records if r["fixture"] == fixture_id)
        cells = []
        for model in models:
            values = [
                r["wer_nf"]
                for r in records
                if r["fixture"] == fixture_id and r["model"] == model and "wer_nf" in r
            ]
            cells.append(f"{statistics.mean(values):.1%}" if values else "—")
        lines.append(f"| {fixture_id} | {language} | " + " | ".join(cells) + " |")

    write_text_atomic(RESULTS / f"report{suffix}.md", "\n".join(lines) + "\n")
    print(f"\nWrote {RESULTS / f'report{suffix}.md'}")


if __name__ == "__main__":
    raise SystemExit(main())
