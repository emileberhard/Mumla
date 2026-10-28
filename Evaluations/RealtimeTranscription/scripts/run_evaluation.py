#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.14"
# ///
"""Run resumable realtime-transcription evaluations against live providers."""

import argparse
import asyncio
import json
import random
import re
import statistics
import subprocess
import sys
from collections import Counter, defaultdict
from collections.abc import Sequence
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from evaluation_support import (
    Fixture,
    load_fixtures,
    select_fixtures,
    write_text_atomic,
)

EVALUATION_DIR = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = EVALUATION_DIR / "fixtures" / "manifest.json"
DEFAULT_RESULTS = EVALUATION_DIR / "results"
PROVIDER_RUNNER = Path(__file__).resolve().with_name("stream_provider.swift")


@dataclass(frozen=True)
class ProviderConfiguration:
    id: str
    provider: str
    model: str | dict[str, str] = ""
    requires_16_khz: bool = False
    language_override: dict[str, str] = field(default_factory=dict)
    extra_arguments: tuple[str, ...] = ()

    def model_for(self, language: str) -> str:
        return (
            self.model.get(language, "") if isinstance(self.model, dict) else self.model
        )

    def language_for(self, language: str) -> str:
        return self.language_override.get(language, language)


CONFIGURATIONS = {
    configuration.id: configuration
    for configuration in [
        ProviderConfiguration(
            "elevenlabs-scribe-v2", "elevenlabs", requires_16_khz=True
        ),
        ProviderConfiguration(
            "gemini-3.5-transcribe-live",
            "gemini",
            model="gemini-3.5-transcribe-live",
            requires_16_khz=True,
        ),
        ProviderConfiguration(
            "elevenlabs-forced-language-manual",
            "elevenlabs",
            requires_16_khz=True,
            extra_arguments=("--commit-strategy", "manual"),
        ),
        ProviderConfiguration(
            "elevenlabs-auto-vad",
            "elevenlabs",
            requires_16_khz=True,
            language_override={"en": "auto", "sv": "auto"},
        ),
        ProviderConfiguration(
            "elevenlabs-auto-manual",
            "elevenlabs",
            requires_16_khz=True,
            language_override={"en": "auto", "sv": "auto"},
            extra_arguments=("--commit-strategy", "manual"),
        ),
        ProviderConfiguration(
            "elevenlabs-auto-meta-context",
            "elevenlabs",
            requires_16_khz=True,
            language_override={"en": "auto", "sv": "auto"},
            extra_arguments=(
                "--previous-text",
                "Swedish and English bilingual dictation.",
            ),
        ),
        ProviderConfiguration(
            "elevenlabs-auto-language-names",
            "elevenlabs",
            requires_16_khz=True,
            language_override={"en": "auto", "sv": "auto"},
            extra_arguments=("--previous-text", "Svenska och English."),
        ),
        ProviderConfiguration(
            "elevenlabs-auto-natural-context",
            "elevenlabs",
            requires_16_khz=True,
            language_override={"en": "auto", "sv": "auto"},
            extra_arguments=(
                "--previous-text",
                "Vi pratar svenska and English.",
            ),
        ),
        ProviderConfiguration(
            "elevenlabs-auto-natural-context-short",
            "elevenlabs",
            requires_16_khz=True,
            language_override={"en": "auto", "sv": "auto"},
            extra_arguments=(
                "--previous-text",
                "Svenska and English.",
            ),
        ),
        ProviderConfiguration(
            "elevenlabs-auto-natural-context-talar",
            "elevenlabs",
            requires_16_khz=True,
            language_override={"en": "auto", "sv": "auto"},
            extra_arguments=(
                "--previous-text",
                "Vi talar svenska and English.",
            ),
        ),
        ProviderConfiguration(
            "elevenlabs-auto-natural-context-explicit",
            "elevenlabs",
            requires_16_khz=True,
            language_override={"en": "auto", "sv": "auto"},
            extra_arguments=(
                "--previous-text",
                "Vi pratar på svenska and in English.",
            ),
        ),
        ProviderConfiguration(
            "elevenlabs-auto-natural-context-long",
            "elevenlabs",
            requires_16_khz=True,
            language_override={"en": "auto", "sv": "auto"},
            extra_arguments=(
                "--previous-text",
                "Här pratar vi svenska and English together.",
            ),
        ),
        ProviderConfiguration(
            "elevenlabs-auto-code-switch-context-a",
            "elevenlabs",
            requires_16_khz=True,
            language_override={"en": "auto", "sv": "auto"},
            extra_arguments=(
                "--previous-text",
                "Ja, absolut. I'll send it later.",
            ),
        ),
        ProviderConfiguration(
            "elevenlabs-auto-code-switch-context-b",
            "elevenlabs",
            requires_16_khz=True,
            language_override={"en": "auto", "sv": "auto"},
            extra_arguments=(
                "--previous-text",
                "Okay, jag fixar det after lunch.",
            ),
        ),
        ProviderConfiguration(
            "elevenlabs-auto-conversation-context",
            "elevenlabs",
            requires_16_khz=True,
            language_override={"en": "auto", "sv": "auto"},
            extra_arguments=(
                "--previous-text",
                "Ja, precis. Okay, let's continue.",
            ),
        ),
        ProviderConfiguration(
            "elevenlabs-auto-swedish-context",
            "elevenlabs",
            requires_16_khz=True,
            language_override={"en": "auto", "sv": "auto"},
            extra_arguments=(
                "--previous-text",
                "Ja, jag fixar det efter lunch.",
            ),
        ),
        ProviderConfiguration(
            "elevenlabs-auto-english-context",
            "elevenlabs",
            requires_16_khz=True,
            language_override={"en": "auto", "sv": "auto"},
            extra_arguments=(
                "--previous-text",
                "Okay, I'll send it after lunch.",
            ),
        ),
        ProviderConfiguration(
            "elevenlabs-auto-language-keyterms",
            "elevenlabs",
            requires_16_khz=True,
            language_override={"en": "auto", "sv": "auto"},
            extra_arguments=("--keyterms", "svenska,English"),
        ),
        ProviderConfiguration(
            "elevenlabs-auto-context-keyterms",
            "elevenlabs",
            requires_16_khz=True,
            language_override={"en": "auto", "sv": "auto"},
            extra_arguments=(
                "--previous-text",
                "Svenska och English.",
                "--keyterms",
                "svenska,English",
            ),
        ),
        ProviderConfiguration(
            "elevenlabs-auto-context-manual",
            "elevenlabs",
            requires_16_khz=True,
            language_override={"en": "auto", "sv": "auto"},
            extra_arguments=(
                "--previous-text",
                "Svenska och English.",
                "--commit-strategy",
                "manual",
            ),
        ),
        ProviderConfiguration(
            "assemblyai-streaming",
            "assemblyai",
            model={
                "en": "universal-streaming-english",
                "sv": "universal-streaming-multilingual",
            },
            requires_16_khz=True,
        ),
        ProviderConfiguration(
            "assemblyai-universal-3.5-pro",
            "assemblyai",
            model="universal-3-5-pro",
            requires_16_khz=True,
        ),
        ProviderConfiguration(
            "deepgram-nova-3",
            "deepgram",
            model="nova-3",
            language_override={"sv": "multi"},
        ),
        ProviderConfiguration("deepgram-nova-2", "deepgram", model="nova-2"),
        ProviderConfiguration(
            "openai-realtime-whisper",
            "openai",
            model="gpt-realtime-whisper",
            extra_arguments=("--vad", "off", "--delay", "high"),
        ),
        ProviderConfiguration(
            "openai-gpt-4o-mini-transcribe",
            "openai",
            model="gpt-4o-mini-transcribe-2025-12-15",
            extra_arguments=("--vad", "semantic:auto"),
        ),
    ]
}

DEFAULT_CONFIGURATION_IDS = (
    "elevenlabs-scribe-v2",
    "assemblyai-streaming",
    "assemblyai-universal-3.5-pro",
    "deepgram-nova-3",
    "deepgram-nova-2",
    "openai-realtime-whisper",
    "openai-gpt-4o-mini-transcribe",
)


@dataclass(frozen=True)
class RunSpec:
    configuration: ProviderConfiguration
    fixture: Fixture
    repetition: int
    wav_path: Path
    sample_rate: int
    log_path: Path

    def command(self, tail_wait: float) -> list[str]:
        command = [
            "swift",
            str(PROVIDER_RUNNER),
            "--provider",
            self.configuration.provider,
            "--wav",
            str(self.wav_path),
            "--rate",
            str(self.sample_rate),
            "--out",
            str(self.log_path),
            "--language",
            self.configuration.language_for(self.fixture.language),
            "--tail-wait",
            str(tail_wait),
        ]
        model = self.configuration.model_for(self.fixture.language)
        if model:
            command.extend(["--model", model])
        command.extend(self.configuration.extra_arguments)
        return command


@dataclass
class RunResult:
    configuration: str
    provider: str
    fixture: str
    repetition: int
    language: str
    stop_latency_ms: int = 0
    word_error_rate: float = 1.0
    filler_normalized_word_error_rate: float = 1.0
    transcript: str = ""
    segments: int = 0
    detected_languages: list[str] = field(default_factory=list)
    provider_errors: list[str] = field(default_factory=list)
    attempts: int = 1
    reused: bool = False
    failure: str | None = None


class InvalidRunLog(ValueError):
    pass


class AdaptiveLimiter:
    """Per-provider AIMD window that starts optimistically at full concurrency."""

    def __init__(self, provider: str, initial: int, ceiling: int):
        self.provider = provider
        self.capacity = initial
        self.ceiling = ceiling
        self.active = 0
        self.condition = asyncio.Condition()

    async def __aenter__(self) -> None:
        async with self.condition:
            await self.condition.wait_for(lambda: self.active < self.capacity)
            self.active += 1

    async def __aexit__(self, *_: object) -> None:
        async with self.condition:
            self.active -= 1
            self.condition.notify_all()

    async def record_success(self) -> None:
        async with self.condition:
            if self.capacity < self.ceiling:
                self.capacity += 1
                self.condition.notify_all()

    async def record_concurrency_rejection(self) -> None:
        async with self.condition:
            new_capacity = max(1, self.capacity // 2)
            if new_capacity < self.capacity:
                self.capacity = new_capacity
                print(
                    f"[{self.provider}] concurrency rejected; window -> {self.capacity}"
                )


CONCURRENCY_FAILURES = ("too many concurrent", "concurrency limit", "rate_limit", "429")
TRANSIENT_FAILURES = CONCURRENCY_FAILURES + (
    "before session ready",
    "connection was lost",
    "network connection was lost",
    "timed out",
    "watchdog timeout",
)
FILLER_WORD = re.compile(r"^(?:u+m+|u+h+|h+m+|e+h+|ö+h+)$", re.IGNORECASE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--results", type=Path, default=DEFAULT_RESULTS)
    parser.add_argument(
        "--runs", type=int, default=3, help="repetitions per configuration and fixture"
    )
    parser.add_argument(
        "--configurations",
        default=",".join(DEFAULT_CONFIGURATION_IDS),
        help="comma-separated configuration ids",
    )
    parser.add_argument(
        "--fixtures", default="", help="comma-separated fixture ids; defaults to all"
    )
    parser.add_argument(
        "--max-provider-concurrency",
        type=int,
        default=0,
        help="initial per-provider window; 0 starts every run concurrently and adapts on rejection",
    )
    parser.add_argument("--retry-attempts", type=int, default=5)
    parser.add_argument("--tail-wait", type=float, default=8)
    parser.add_argument(
        "--rerun", action="store_true", help="replace otherwise reusable completed logs"
    )
    parser.add_argument(
        "--plan",
        action="store_true",
        help="validate and print the run plan without network calls",
    )
    parser.add_argument("--list-configurations", action="store_true")
    return parser.parse_args()


def selected_configurations(requested: str) -> list[ProviderConfiguration]:
    names = [name.strip() for name in requested.split(",") if name.strip()]
    unknown = set(names) - CONFIGURATIONS.keys()
    if unknown:
        raise ValueError(
            f"unknown configuration ids: {', '.join(sorted(unknown))}; "
            f"available: {', '.join(CONFIGURATIONS)}"
        )
    return [CONFIGURATIONS[name] for name in names]


def normalized_words(text: str) -> list[str]:
    return re.sub(r"[^\w' ]", " ", text.lower(), flags=re.UNICODE).split()


def word_error_rate(reference: list[str], hypothesis: list[str]) -> float:
    distances = list(range(len(hypothesis) + 1))
    for reference_index, reference_word in enumerate(reference, start=1):
        previous = distances[0]
        distances[0] = reference_index
        for hypothesis_index, hypothesis_word in enumerate(hypothesis, start=1):
            current = distances[hypothesis_index]
            distances[hypothesis_index] = min(
                distances[hypothesis_index] + 1,
                distances[hypothesis_index - 1] + 1,
                previous + (reference_word != hypothesis_word),
            )
            previous = current
    return distances[-1] / max(1, len(reference))


def without_fillers(words: list[str]) -> list[str]:
    return [word for word in words if not FILLER_WORD.fullmatch(word)]


def analyze_log(path: Path, reference: str) -> dict[str, Any]:
    stop_time: float | None = None
    commits: list[tuple[float, str]] = []
    assemblyai_turns: dict[int, tuple[float, str]] = {}
    detected_languages: list[str] = []
    provider_errors: list[str] = []
    saw_event = False
    with path.open() as log:
        for line_number, line in enumerate(log, start=1):
            saw_event = True
            try:
                entry = json.loads(line)
            except json.JSONDecodeError as error:
                raise InvalidRunLog(
                    f"invalid JSONL on line {line_number}: {error}"
                ) from error
            if not isinstance(entry, dict):
                raise InvalidRunLog(f"line {line_number} must contain a JSON object")

            event = entry.get("event")
            event_time = entry.get("t")
            if not isinstance(event_time, int | float):
                raise InvalidRunLog("event is missing a numeric timestamp")
            if isinstance(event, str):
                if event.startswith("STOP"):
                    stop_time = event_time
                continue
            if not isinstance(event, dict) or entry.get("dir") == "out":
                continue

            kind = (
                event.get("type")
                or event.get("message_type")
                or event.get("message")
                or ""
            )
            if kind == "conversation.item.input_audio_transcription.completed":
                text = event.get("transcript", "")
                if text.strip():
                    commits.append((event_time, text))
            elif kind == "committed_transcript":
                text = event.get("text", "")
                if text.strip():
                    commits.append((event_time, text))
            elif text := (
                (event.get("serverContent") or {})
                .get("inputTranscription", {})
                .get("text", "")
            ):
                if text.strip():
                    commits.append((event_time, text))
            elif kind == "committed_transcript_with_timestamps":
                language_code = event.get("language_code", "")
                if language_code:
                    detected_languages.append(language_code)
            elif kind == "Turn" and event.get("end_of_turn"):
                text = event.get("transcript", "")
                if text.strip():
                    turn_order = event.get("turn_order", len(assemblyai_turns))
                    assemblyai_turns[turn_order] = (event_time, text)
            elif kind == "AddTranscript":
                text = (event.get("metadata") or {}).get("transcript", "")
                if text.strip():
                    commits.append((event_time, text))
            elif kind == "Results" and event.get("is_final"):
                alternatives = ((event.get("channel") or {}).get("alternatives")) or [
                    {}
                ]
                text = alternatives[0].get("transcript", "")
                if text.strip():
                    commits.append((event_time, text))
            elif kind.lower().endswith("error") or kind == "error":
                provider_errors.append(json.dumps(event, ensure_ascii=False)[:300])
            elif event.get("error"):
                provider_errors.append(
                    json.dumps(event["error"], ensure_ascii=False)[:300]
                )

    if not saw_event:
        raise InvalidRunLog("log is empty")

    if stop_time is None:
        raise InvalidRunLog("log has no STOP marker and is not reusable")

    commits.extend(assemblyai_turns.values())
    commits.sort(key=lambda commit: commit[0])
    transcript = " ".join(text.strip() for _, text in commits if text.strip())
    final_time = commits[-1][0] if commits else None
    stop_latency_ms = (
        round((final_time - stop_time) * 1_000)
        if final_time is not None and final_time > stop_time
        else 0
    )
    reference_words = normalized_words(reference)
    transcript_words = normalized_words(transcript)
    return {
        "stop_latency_ms": stop_latency_ms,
        "word_error_rate": round(word_error_rate(reference_words, transcript_words), 4)
        if transcript
        else 1.0,
        "filler_normalized_word_error_rate": (
            round(
                word_error_rate(
                    without_fillers(reference_words), without_fillers(transcript_words)
                ),
                4,
            )
            if transcript
            else 1.0
        ),
        "transcript": transcript,
        "segments": len(commits),
        "detected_languages": detected_languages,
        "provider_errors": provider_errors,
    }


def ensure_16_khz(wav_path: Path, cache_dir: Path) -> Path:
    output = cache_dir / f"{wav_path.stem}-16khz.wav"
    if output.is_file() and output.stat().st_mtime_ns >= wav_path.stat().st_mtime_ns:
        return output
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".tmp.wav")
    subprocess.run(
        [
            "afconvert",
            "-f",
            "WAVE",
            "-d",
            "LEI16@16000",
            "-c",
            "1",
            str(wav_path),
            str(temporary),
        ],
        check=True,
        capture_output=True,
    )
    temporary.replace(output)
    return output


def build_plan(
    configurations: list[ProviderConfiguration],
    fixtures: list[Fixture],
    manifest_path: Path,
    results_dir: Path,
    runs: int,
    prepare_audio: bool,
) -> list[RunSpec]:
    missing = [
        fixture.id
        for fixture in fixtures
        if not fixture.audio_path(manifest_path).is_file()
    ]
    if missing:
        raise ValueError(
            "missing fixture audio: "
            f"{', '.join(missing)}; run Evaluations/RealtimeTranscription/scripts/generate_fixtures.py"
        )

    cache_dir = results_dir / "audio-cache"
    plan: list[RunSpec] = []
    for configuration in configurations:
        for fixture in fixtures:
            source_wav = fixture.audio_path(manifest_path)
            wav_path = (
                ensure_16_khz(source_wav, cache_dir)
                if configuration.requires_16_khz and prepare_audio
                else source_wav
            )
            sample_rate = 16_000 if configuration.requires_16_khz else 24_000
            for repetition in range(1, runs + 1):
                log_path = (
                    results_dir
                    / "raw"
                    / configuration.id
                    / f"{fixture.id}-run-{repetition:02d}.jsonl"
                )
                plan.append(
                    RunSpec(
                        configuration,
                        fixture,
                        repetition,
                        wav_path,
                        sample_rate,
                        log_path,
                    )
                )
    return plan


async def terminate_process(process: asyncio.subprocess.Process) -> None:
    if process.returncode is not None:
        return
    process.terminate()
    try:
        await asyncio.wait_for(process.wait(), timeout=3)
    except TimeoutError:
        process.kill()
        await process.wait()


async def run_spec(
    spec: RunSpec,
    limiter: AdaptiveLimiter,
    tail_wait: float,
    retry_attempts: int,
    reuse: bool,
) -> RunResult:
    result = RunResult(
        configuration=spec.configuration.id,
        provider=spec.configuration.provider,
        fixture=spec.fixture.id,
        repetition=spec.repetition,
        language=spec.fixture.language,
    )
    if reuse and spec.log_path.is_file():
        try:
            for key, value in analyze_log(
                spec.log_path, spec.fixture.reference
            ).items():
                setattr(result, key, value)
            result.reused = True
            return result
        except InvalidRunLog as error:
            print(
                f"[{spec.configuration.id}/{spec.fixture.id}] incomplete cached log: {error}; rerunning"
            )

    spec.log_path.parent.mkdir(parents=True, exist_ok=True)
    failure = ""
    for attempt in range(1, retry_attempts + 1):
        process: asyncio.subprocess.Process | None = None
        try:
            async with limiter:
                process = await asyncio.create_subprocess_exec(
                    *spec.command(tail_wait),
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.PIPE,
                )
                _, stderr = await process.communicate()
        except asyncio.CancelledError:
            if process is not None:
                await terminate_process(process)
            raise

        failed_log = spec.log_path.with_suffix(spec.log_path.suffix + ".failed")
        if process.returncode == 0 and spec.log_path.is_file():
            try:
                analysis = analyze_log(spec.log_path, spec.fixture.reference)
            except InvalidRunLog as error:
                failure = str(error)
            else:
                await limiter.record_success()
                failed_log.unlink(missing_ok=True)
                for key, value in analysis.items():
                    setattr(result, key, value)
                result.attempts = attempt
                return result
        else:
            failure = (stderr or b"").decode(errors="replace")[
                -500:
            ] or f"exit {process.returncode}"
            if failed_log.is_file():
                failure += " | " + failed_log.read_text(errors="replace")[-500:]

        lowered_failure = failure.lower()
        if not any(marker in lowered_failure for marker in TRANSIENT_FAILURES):
            break
        if any(marker in lowered_failure for marker in CONCURRENCY_FAILURES):
            await limiter.record_concurrency_rejection()
        if attempt < retry_attempts:
            await asyncio.sleep(min(30, 2**attempt) + random.uniform(0, 1))

    result.attempts = attempt
    result.failure = failure.strip()
    return result


def formatted_range(values: Sequence[int | float]) -> str:
    if len(values) == 1:
        return f"{values[0]:.0f}"
    return f"{statistics.mean(values):.0f} ({min(values):.0f}-{max(values):.0f})"


def unexpected_language_rate(results: list[RunResult]) -> str:
    expected_codes = {
        "en": {"en", "eng"},
        "sv": {"sv", "swe"},
    }
    detected = [
        (result.language, code)
        for result in results
        for code in result.detected_languages
    ]
    if not detected:
        return "—"
    unexpected = sum(
        code not in expected_codes[language] for language, code in detected
    )
    return f"{unexpected / len(detected):.1%}"


def render_report(results: list[RunResult]) -> str:
    successful = [result for result in results if result.failure is None]
    failed = [result for result in results if result.failure is not None]
    lines = ["# Realtime transcription evaluation", ""]
    by_language: dict[str, list[RunResult]] = defaultdict(list)
    for result in successful:
        by_language[result.language].append(result)

    for language, language_results in sorted(by_language.items()):
        lines.extend(
            [
                f"## {language}",
                "",
                "| Configuration | Stop-to-final ms | WER | WER without fillers | Wrong language | Runs |",
                "|---|---:|---:|---:|---:|---:|",
            ]
        )
        by_configuration: dict[str, list[RunResult]] = defaultdict(list)
        for result in language_results:
            by_configuration[result.configuration].append(result)
        rows = sorted(
            by_configuration.items(),
            key=lambda item: statistics.mean(
                result.filler_normalized_word_error_rate for result in item[1]
            ),
        )
        for configuration, configuration_results in rows:
            latencies = [result.stop_latency_ms for result in configuration_results]
            wer = statistics.mean(
                result.word_error_rate for result in configuration_results
            )
            filler_wer = statistics.mean(
                result.filler_normalized_word_error_rate
                for result in configuration_results
            )
            lines.append(
                f"| {configuration} | {formatted_range(latencies)} | {wer:.1%} | "
                f"{filler_wer:.1%} | {unexpected_language_rate(configuration_results)} | "
                f"{len(configuration_results)} |"
            )
        lines.append("")

    if failed:
        lines.extend(["## Failed runs", ""])
        for result in failed:
            lines.append(
                f"- {result.configuration} / {result.fixture} run {result.repetition}: {result.failure}"
            )
        lines.append("")

    error_runs = [result for result in successful if result.provider_errors]
    if error_runs:
        lines.extend(["## Runs with provider error events", ""])
        for result in error_runs:
            lines.append(
                f"- {result.configuration} / {result.fixture} run {result.repetition}: "
                f"{result.provider_errors[0]}"
            )
        lines.append("")
    return "\n".join(lines)


async def run_evaluation(args: argparse.Namespace) -> int:
    manifest_path = args.manifest.resolve()
    results_dir = args.results.resolve()
    fixtures = select_fixtures(load_fixtures(manifest_path), args.fixtures)
    configurations = selected_configurations(args.configurations)
    plan = build_plan(
        configurations,
        fixtures,
        manifest_path,
        results_dir,
        args.runs,
        prepare_audio=not args.plan,
    )
    provider_counts = Counter(spec.configuration.provider for spec in plan)
    reusable = sum(spec.log_path.is_file() and not args.rerun for spec in plan)
    print(
        f"{len(plan)} runs: {len(configurations)} configurations x {len(fixtures)} fixtures x "
        f"{args.runs} repetitions; {reusable} completed logs reusable"
    )
    if args.plan:
        for provider, count in sorted(provider_counts.items()):
            window = args.max_provider_concurrency or count
            print(f"{provider}: {count} runs, initial concurrency {min(window, count)}")
        return 0

    limiters = {
        provider: AdaptiveLimiter(
            provider,
            initial=min(args.max_provider_concurrency or count, count),
            ceiling=count,
        )
        for provider, count in provider_counts.items()
    }
    results = await asyncio.gather(
        *[
            run_spec(
                spec,
                limiters[spec.configuration.provider],
                args.tail_wait,
                args.retry_attempts,
                reuse=not args.rerun,
            )
            for spec in plan
        ]
    )

    summary = (
        json.dumps([asdict(result) for result in results], ensure_ascii=False, indent=2)
        + "\n"
    )
    write_text_atomic(results_dir / "summary.json", summary)
    write_text_atomic(results_dir / "report.md", render_report(results) + "\n")
    failures = sum(result.failure is not None for result in results)
    reused_count = sum(result.reused for result in results)
    print(
        f"done: {len(results) - failures} successful, {failures} failed, {reused_count} reused -> "
        f"{results_dir / 'report.md'}"
    )
    return 1 if failures else 0


def main() -> None:
    args = parse_args()
    if args.list_configurations:
        for configuration in CONFIGURATIONS.values():
            print(f"{configuration.id}: {configuration.provider}")
        return
    if args.runs < 1 or args.retry_attempts < 1 or args.max_provider_concurrency < 0:
        raise SystemExit(
            "runs and retry attempts must be positive; concurrency cannot be negative"
        )
    if args.tail_wait < 0:
        raise SystemExit("tail wait cannot be negative")
    try:
        raise SystemExit(asyncio.run(run_evaluation(args)))
    except KeyboardInterrupt:
        print(
            "interrupted; completed atomic run logs were retained and will be reused next time",
            file=sys.stderr,
        )
        raise SystemExit(130) from None
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from None


if __name__ == "__main__":
    main()
