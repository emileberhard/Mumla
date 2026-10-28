import asyncio
import json
from pathlib import Path

import pytest
from evaluation_support import (
    Fixture,
    load_fixtures,
    select_fixtures,
    write_text_atomic,
)
from run_evaluation import (
    CONFIGURATIONS,
    AdaptiveLimiter,
    InvalidRunLog,
    ProviderConfiguration,
    RunSpec,
    analyze_log,
    normalized_words,
    run_spec,
    selected_configurations,
    without_fillers,
    word_error_rate,
)

MANIFEST = Path(__file__).resolve().parent.parent / "fixtures" / "manifest.json"


def write_log(path: Path, entries: list[dict]) -> None:
    path.write_text("".join(json.dumps(entry) + "\n" for entry in entries))


def test_manifest_is_valid_and_uses_consistent_ids() -> None:
    fixtures = load_fixtures(MANIFEST)

    assert len(fixtures) == 36
    assert {fixture.language for fixture in fixtures} == {"en", "sv"}
    assert sum(fixture.language == "en" for fixture in fixtures) == 18
    assert sum(fixture.language == "sv" for fixture in fixtures) == 18
    assert all(fixture.file == f"{fixture.id}.wav" for fixture in fixtures)
    assert fixtures[0].audio_path(MANIFEST).is_file()
    assert "[pauses]" not in fixtures[0].reference


def test_fixture_selection_preserves_manifest_order() -> None:
    fixtures = load_fixtures(MANIFEST)

    selected = select_fixtures(fixtures, "sv-teen-note,en-teen-note")

    assert [fixture.id for fixture in selected] == ["en-teen-note", "sv-teen-note"]


def test_fixture_selection_rejects_unknown_ids() -> None:
    with pytest.raises(ValueError, match="unknown fixture ids: missing"):
        select_fixtures(load_fixtures(MANIFEST), "missing")


def test_gemini_live_configuration_matches_app_audio_contract() -> None:
    configuration = CONFIGURATIONS["gemini-3.5-transcribe-live"]

    assert configuration.provider == "gemini"
    assert configuration.model == "gemini-3.5-transcribe-live"
    assert configuration.requires_16_khz


def test_configuration_selection_uses_explicit_names() -> None:
    configurations = selected_configurations(
        "elevenlabs-scribe-v2,assemblyai-universal-3.5-pro"
    )

    assert [configuration.provider for configuration in configurations] == [
        "elevenlabs",
        "assemblyai",
    ]


def test_word_error_rate_and_filler_normalization() -> None:
    reference = normalized_words("Um, hello there")
    hypothesis = normalized_words("hello there")

    assert word_error_rate(reference, hypothesis) == pytest.approx(1 / 3)
    assert word_error_rate(without_fillers(reference), without_fillers(hypothesis)) == 0


def test_analysis_extracts_stop_latency_and_transcript(tmp_path: Path) -> None:
    log = tmp_path / "run.jsonl"
    write_log(
        log,
        [
            {"t": 1.0, "audio_sent_s": 0, "dir": "marker", "event": "session ready"},
            {
                "t": 10.0,
                "audio_sent_s": 9,
                "dir": "marker",
                "event": "STOP: commit requested",
            },
            {
                "t": 10.25,
                "audio_sent_s": 9,
                "dir": "in",
                "event": {
                    "type": "conversation.item.input_audio_transcription.completed",
                    "transcript": "hello there",
                },
            },
            {
                "t": 10.3,
                "audio_sent_s": 9,
                "dir": "in",
                "event": {
                    "message_type": "committed_transcript_with_timestamps",
                    "language_code": "en",
                    "text": "hello there",
                    "words": [],
                },
            },
        ],
    )

    analysis = analyze_log(log, "um hello there")

    assert analysis["stop_latency_ms"] == 250
    assert analysis["transcript"] == "hello there"
    assert analysis["word_error_rate"] == pytest.approx(0.3333)
    assert analysis["filler_normalized_word_error_rate"] == 0
    assert analysis["detected_languages"] == ["en"]


def test_analysis_rejects_incomplete_logs(tmp_path: Path) -> None:
    log = tmp_path / "run.jsonl"
    write_log(log, [{"t": 1, "dir": "marker", "event": "session ready"}])

    with pytest.raises(InvalidRunLog, match="no STOP marker"):
        analyze_log(log, "hello")


def test_analysis_reads_gemini_committed_transcript(tmp_path: Path) -> None:
    log = tmp_path / "gemini.jsonl"
    write_log(
        log,
        [
            {"t": 10, "dir": "marker", "event": "STOP: commit requested"},
            {
                "t": 10.4,
                "dir": "in",
                "event": {
                    "serverContent": {"inputTranscription": {"text": "hello there"}}
                },
            },
        ],
    )

    analysis = analyze_log(log, "hello there")

    assert analysis["stop_latency_ms"] == 400
    assert analysis["transcript"] == "hello there"
    assert analysis["word_error_rate"] == 0


def test_completed_log_is_reused_without_starting_a_provider(tmp_path: Path) -> None:
    log = tmp_path / "run.jsonl"
    write_log(
        log,
        [
            {"t": 1, "dir": "marker", "event": "STOP: commit requested"},
            {
                "t": 1.1,
                "dir": "in",
                "event": {"message_type": "committed_transcript", "text": "hello"},
            },
        ],
    )
    fixture = Fixture(
        "fixture", "fixture.wav", "en", "Voice", "short", "p", "s", "s", "hello"
    )
    configuration = ProviderConfiguration("config", "elevenlabs")
    spec = RunSpec(configuration, fixture, 1, tmp_path / "missing.wav", 24_000, log)
    limiter = AdaptiveLimiter("elevenlabs", initial=1, ceiling=1)

    result = asyncio.run(
        run_spec(spec, limiter, tail_wait=0, retry_attempts=1, reuse=True)
    )

    assert result.reused is True
    assert result.failure is None
    assert result.transcript == "hello"


def test_adaptive_limiter_halves_then_additively_recovers() -> None:
    async def exercise() -> tuple[int, int]:
        limiter = AdaptiveLimiter("provider", initial=8, ceiling=10)
        await limiter.record_concurrency_rejection()
        reduced = limiter.capacity
        await limiter.record_success()
        return reduced, limiter.capacity

    assert asyncio.run(exercise()) == (4, 5)


def test_atomic_text_replacement(tmp_path: Path) -> None:
    path = tmp_path / "report.md"
    path.write_text("old")

    write_text_atomic(path, "new")

    assert path.read_text() == "new"
    assert list(tmp_path.iterdir()) == [path]
