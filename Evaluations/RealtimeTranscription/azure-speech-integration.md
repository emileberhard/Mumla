# Azure Speech: implementation and evidence

Implemented and verified 2026-09-05. The exact SpeechKit dependency is maintained
in `Mumla.xcodeproj/project.xcproj`; API availability and limits must still be checked live.

## Implemented path

Mumla uses the **Azure Speech provider** with **MAI-Transcribe-2** and native
`clean` formatting. A recording-lifetime HTTP upload overlaps transfer with
speaking; the completed-file adapter remains available for recovery.

The request starts when dictation begins, sends audio continuously, and closes
the multipart body when dictation stops. This overlaps connection establishment and
audio transfer with speaking. The API returns one final response; it does not
provide incremental transcripts. Server inference may still happen after EOF.

## API choices

| Route | Contract and model selection | Fit |
| --- | --- | --- |
| Azure Speech fast transcription | `POST https://RESOURCE.cognitiveservices.azure.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15`; multipart `audio` and JSON `definition`; `enhancedMode.model` selects MAI | Recommended; exact MAI model selection and direct provider options |
| Default fast transcription / LLM Speech | Same REST endpoint, different `definition` settings; LLM Speech uses `enhancedMode.enabled` and task settings | Same provider family, with distinct supported options |
| Azure Voice Live | WebSocket `/voice-live/realtime`; the URL model selects the conversational model, while `input_audio_transcription.model` selects the transcriber | Docs expose the unversioned `mai-transcribe` alias; exact MAI-2 selection and equivalence are unverified |
| Azure OpenAI audio transcription | Separate deployment-based `/openai/deployments/DEPLOYMENT/audio/transcriptions` route, multipart `file`, separate authentication headers | OpenAI-shaped protocol for deployed transcription models; no evidence this exposes MAI-2 |
| OpenRouter transcription | `/api/v1/audio/transcriptions`, model `microsoft/mai-transcribe-2`; multipart or JSON audio | Aggregator alternative; Azure-specific feature passthrough and progressive upload unverified |

These are not interchangeable base URLs. SpeechKit's OpenAI batch adapter
hardcodes its endpoint, Bearer authentication, and `file/model/language/prompt`
form fields. Azure Speech uses a different request and response schema.

Sources: [MAI](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/mai-transcribe),
[LLM Speech](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/llm-speech),
[Voice Live reference](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/voice-live-api-reference-2026-04-10),
[Azure OpenAI](https://learn.microsoft.com/en-us/azure/foundry/openai/whisper-quickstart),
[OpenRouter](https://openrouter.ai/docs/api/api-reference/stt/create-transcription).

## Authentication

| Method | Direct REST behavior | Probe result |
| --- | --- | --- |
| Resource key | `Ocp-Apim-Subscription-Key` header | MAI-2 and MAI-1.5 returned HTTP 200 |
| Microsoft Entra ID | `Authorization: Bearer ...`, cognitive-services scope, custom resource subdomain, Speech data-plane role | Token acquisition worked; current signed-in user got HTTP 401 for missing `SpeechServices/speechrest/transcriptions/action` |
| Speech STS token | Short-lived token obtained by exchanging the key at regional `issueToken` | Issuance worked, but this transcription endpoint rejected its audience with HTTP 401 |

SpeechKit exposes an explicit credential choice: key or an async `@Sendable`
access token supplier. The caller owns Entra login, refresh, and expiry; SpeechKit need
not embed an Azure identity SDK or client secret. A static token is sufficient
for a probe, not a durable login flow. Do not treat a Speech STS token as an
Entra token merely because both use the Bearer header.

The generic Contributor role can retrieve keys but does not grant Speech data
access; Microsoft documents `Cognitive Services Speech User` or
`Cognitive Services User` for that boundary. Never distribute a resource key
with the app.

Sources: [fast transcription authentication](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/fast-transcription-create),
[Speech RBAC](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/role-based-access-control).

## What the Swift probes establish

Swift 6.4, strict concurrency and warnings-as-errors, Xcode 27 beta 5; macOS,
one Azure Speech resource, synthetic English speech, mono 16 kHz
PCM WAV, HTTP/2. Each row is one request, not a statistical benchmark.

| Audio | Upload | Total request time | Producer finish → response |
| --- | --- | ---: | ---: |
| 4.84 s | Complete WAV | 456 ms | N/A |
| 4.84 s | Paced, known WAV lengths | 5,038 ms | 190 ms |
| 4.84 s | Paced, unknown WAV lengths | 5,076 ms | 232 ms |
| 20.03 s | Complete WAV | 523 ms | N/A |
| 20.03 s | Paced, unknown WAV lengths | 20,375 ms | 338 ms |

The unknown-length variant sets RIFF and data chunk sizes to `0xffffffff` and
omits HTTP Content-Length. URLSession reported roughly 151 KB and 637 KB sent
before the respective producers finished. Both returned nonempty final
transcripts, with the same character counts as their completed-file controls.
MAI-1.5 also succeeded through the same model field. An intentionally invalid
model was rejected, rather than silently selecting the default.

This proves progressive HTTP transfer and successful final decoding for these
inputs. It does **not** establish server inference scheduling, exact transcript
equivalence, representative accuracy, iPhone behavior, cellular performance,
long-session limits, or percentile latency. Responses did not echo the served
model ID; the model field is the requested model, not provider attestation.
The unknown-length WAV convention is experimentally accepted here, not an
explicit streaming guarantee in the MAI documentation.

## Shared implementation

SpeechKit exposes `ProgressiveTranscriptionProvider` and the reusable
`ProgressiveTranscriptionSession`. Adapters supply HTTP headers, body framing,
audio rate/size limits, and final-response decoding. The generic transport owns
bounded buffering, cancellation, one-time finalization, response limits, and
replay/redirect rejection. Azure is the first verified adapter; other batch
APIs need compatibility evidence before opting in.

`StreamingHTTPBody` confines native OutputStream operations to a dedicated run
loop, so they do not block microphone callbacks or Swift's cooperative executor.
The actor-owned session accepts ordered PCM16 mono chunks and returns one final
result. The standalone probe's polling writer is not the production writer.

`Shared/Core/ProgressiveDictationSession.swift` adapts that SDK session to the
app's existing PCM sender, recovery recording, committed-text event, and terminal
finalization event. It never invents partial transcripts. The iOS containing app
retains microphone ownership and its mixable audio session; MAI dictation keeps
batch-style interruption pause/resume. Native clean formatting avoids an extra
Gemini cleanup call.

`AzureSpeechModel.enhanced(String)` supports other model IDs on the same REST
API, while `.fast` and `.llmSpeech` select its other modes. This is not a promise
that arbitrary Foundry catalog models share this API or its feature set. Model
metadata records the requested ID because Azure does not echo a served-model ID.

The apps reach Azure Speech only through Mumla's access service, which
forwards to llm-router's `azure-speech` vendor route; the router owns the
resource endpoint and key, and the apps hold only a device session. The
transport probe below uses a developer router key.

## Dictionary regression and acceptance

The first minimal SDK live test used an empty dictionary and passed. The
installed app's 57-term dictionary exposed a live MAI-2 limit absent from the
MAI documentation: context lists cannot exceed 50 items. The app received
HTTP 400. Its iOS stop handler also ignored errors arriving during finalization,
so that original rejection was initially hidden behind a timeout.

The SDK now sends the first 50 normalized terms for MAI-2 and returns a warning;
the full supplied and saved dictionary remains unchanged. The SDK exposes this
limit for app settings. Unit tests cover 50, 51, and 57 terms. Stop handling now
preserves errors received during finalization and exits the wait promptly.

The app-level live acceptance runs from the signed Debug Mac app through the
access service, with the production factory, session, PCM sender, final event
and archived-original recovery, English/Swedish hints, native clean formatting
and 57 synthetic dictionary terms, more than the service limit:

```bash
just test-access-live
```

Both repositories' `AGENTS.md` require realistic live integration tests before
external-provider changes are handed off, merged, or released.

The app-level test reproduced HTTP 400 before the fix and passed afterward
with the matching 57-term dictionary: one test executed, one passed, none skipped.
It checks meaningful output, the expected ending, exactly one committed result,
a terminal event, and batch recovery. Emil then confirmed that the fixed iPhone
build worked. The SDK's own updated live test also passed with 57 supplied terms
and measured a 231 ms finish-to-result tail in one run.

The earlier transport table and these smoke tests do not establish p50/p95
end-to-end latency, broad transcription accuracy, or cellular performance.
A larger comparison should measure tap-stop, last PCM, body close, final result,
and insertion against the same multilingual fixtures and network conditions.
The unknown-length WAV convention remains experimentally accepted rather than
an explicit Microsoft streaming guarantee. MAI-Transcribe-2 remains a preview.

Apple documents the HTTP mechanism in
[Uploading streams of data](https://developer.apple.com/documentation/foundation/uploading-streams-of-data).

## Reproduce the transport probe

Compile from the repository root without changing the selected system Xcode:

```bash
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.5.app/Contents/Developer \
  xcrun swiftc -swift-version 6 -strict-concurrency=complete \
  -warnings-as-errors -parse-as-library \
  Evaluations/RealtimeTranscription/scripts/azure_speech_probe.swift \
  -o /tmp/azure-speech-probe
```

The probe sends this device's router key from `~/.config/llm-router/key` to the
origin in `LLM_ROUTER_ORIGIN`. Run with synthetic audio and its measured
duration:

```bash
/tmp/azure-speech-probe buffered /path/to/synthetic.wav MAI-Transcribe-2 4.84
/tmp/azure-speech-probe paced /path/to/synthetic.wav MAI-Transcribe-2 4.84
```

`paced` simulates arriving audio from an in-memory fixture in approximately
100 ms chunks. Its duration argument controls pacing, not audio decoding. It
does not rewrite WAV sizes: supply a separately prepared unknown-length fixture
for that experiment. `standard` omits enhanced mode. `entra` and `speech-token`
select the Bearer header; they do not obtain credentials. The probe limits audio
to 10 MB and pacing to 60 seconds, emits counts/timings/status instead of
transcripts or raw service messages, and makes no automatic retries. Local
measurement JSON belongs in ignored `results/azure-speech-probe/`.
