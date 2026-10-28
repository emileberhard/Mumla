# Realtime transcription evaluation

This package measures transcription accuracy and tap-stop latency against the
live realtime providers supported by Mumla. It is developer tooling, not
production app code.

The [Azure Speech integration notes](azure-speech-integration.md) document
MAI-Transcribe-2, the app live regression, and the progressive-upload probe.

## Layout

- `fixtures/manifest.json` is the canonical fixture catalogue: stable IDs,
  filenames, languages, voices, synthesis direction, and reference transcripts.
- `fixtures/*.wav` contains the committed audio corpus so evaluation runs are
  reproducible and never require routine fixture synthesis. The corpus includes
  both longer natural dictation and 26 short, deliberately varied
  language-detection stress cases.
- `scripts/generate_fixtures.py` synthesizes only missing fixtures by default.
- `scripts/stream_provider.swift` runs one fixture against one provider and
  writes its complete WebSocket event stream atomically as JSONL.
- `scripts/run_evaluation.py` runs the full matrix, calculates WER and
  stop-to-final latency, and writes `summary.json` plus `report.md`.
- `tests/` covers manifest validation, event analysis, resume behavior, and the
  adaptive concurrency window without making provider calls.

The scripts send this device's router key from `~/.config/llm-router/key` to
the HTTPS origin in `LLM_ROUTER_ORIGIN`.

Local `results/` are ignored because raw provider events contain transcripts.
Do not commit them without reviewing their contents.

## Generate fixtures

```bash
export LLM_ROUTER_ORIGIN=https://router.example
just realtime-eval-fixtures
```

Generation is only for deliberate corpus replacement or extension. It starts
every selected missing fixture concurrently and writes each WAV atomically.
Existing fixtures are preserved unless `--replace` is explicitly supplied.

## Run or resume an evaluation

```bash
export LLM_ROUTER_ORIGIN=https://router.example
just realtime-eval
```

Every provider/configuration/fixture/repetition combination starts
optimistically in parallel. If a provider rejects concurrency, only that
provider's window follows additive-increase/multiplicative-decrease behavior;
other providers continue independently.

Each completed run log is an atomic resume checkpoint. Pressing Ctrl-C stops
active child processes but retains completed logs. Running the same command
again reuses those logs and schedules only unfinished runs. Use `--rerun` when
the completed measurements should intentionally be replaced.

Useful examples:

```bash
just realtime-eval --plan
just realtime-eval --fixtures en-developer-message --runs 1
just realtime-eval --configurations elevenlabs-scribe-v2,openai-realtime-whisper
just realtime-eval --max-provider-concurrency 5
```

List provider configurations with:

```bash
Evaluations/RealtimeTranscription/scripts/run_evaluation.py --list-configurations
```
