# Only my voice

Status: proposed. The open measurements at the end gate the default.

By default, a dictation contains only what the dictating user said. Other people
in the room, a TV and a phone on speaker are left out. A setting switches to
transcribing everyone. Transcription stays with Azure MAI-Transcribe-2 through
the [access service](mumla-access-service.md); deciding which voice is the user
happens on the device.

## Goals and constraints

- Never lose the user's own words. When the evidence is unclear, keep the text:
  a leaked "Yeah?" from someone else costs less than a missing sentence.
- Single-voice dictations, almost all of them, get exactly today's text and pay
  no on-device work before delivery.
- Everyone keeps today's text, including the model's line breaks between
  speakers.
- The added latency between stop and delivery stays small: the provider's
  diarization cost plus a few tens of milliseconds on device.
- The voice profile is a biometric template. It never leaves the device: no
  CloudKit, KVS, iCloud Keychain, backup, App Group, diagnostics or service.
- Works on the iOS 26 and macOS 26 floor and is tuned for iOS 27.2 and later.
- Old app versions keep reading every result written by new ones.
- Overlapping speech, such as a TV over the user's own voice, is out of scope:
  diarization merges it into the user's label and only target-speaker
  extraction separates it.

## Evidence

A small model screened 5,248 of the maintainer's recent transcripts for
possible background speech. Diarizing the 67 strongest candidates with
MAI-Transcribe-2 found two or more speaker labels in 20. Scoring their audio
with WeSpeaker ResNet34 against a voiceprint from earlier dictations:

| Rule | Result |
| --- | --- |
| Keep the label with the most words | Unsafe: a long TV ad wins, and the user's words are dropped |
| Keep the first and the most-words labels | Safe but leaky: keeps the ad and some interjections |
| Keep the label that best matches the voiceprint | Right label in 18 of 19 scorable recordings |
| Keep labels above a fixed voiceprint score | Unsafe: one muffled recording scored 0.29 and lost everything |

The one failure was the user's own voice split over two labels while the phone
lay on fabric. Comparing that second label with the user's other label in the
same recording gave 0.84; the other speakers' labels scored 0.10 to 0.45 against
the user's audio in their recordings. A same-recording comparison removes the
microphone and room mismatch that defeats a stored voiceprint. The design rests
on that check. Diarization added about 0.4 s on a 28 s file.

The recordings, transcripts and scores stay outside the repository; this
document records only aggregates.

Platform facts, checked on 2026-11-06:

- Azure diarization labels speakers anonymously per phrase, with word
  timestamps on request. Azure has no speaker identification (Speaker
  Recognition is retired) and no target-speaker option.
- No Apple framework in the iOS 27.2 SDK offers speaker embeddings,
  identification or diarization. `AUSoundIsolation` and Voice Isolation keep
  every voice.
- iOS 27 requires `com.apple.developer.background-tasks.continued-processing.inference`
  for any Neural Engine use while the app is in the background, and the
  keyboard flow finishes dictations in the background.

## Design

The filter is a pure transformation between the provider's reply and delivery:

```
attributed phrases + provider PCM + voice profile
  → speech per label → one embedding per label → user labels → delivered text
```

### Service

The `start` message gains an optional `"voices": true`. With it, the service
adds `diarization: {enabled: true}` and `timestamps: "word"` to the Azure
definition. It then validates the response and replies with `text` unchanged
plus `phrases`: each phrase has its integer `speaker`, its `text` and its
speech spans in milliseconds. The service merges word timestamps into spans,
so word text never crosses the protocol twice. Without the field, the request
and reply stay byte for byte as today, so older apps are unaffected. The HTTP
route for pre-1.1 installs stays as it is. The response cap covers the longest
grant with word timestamps. Transcript content stays out of service logs.

### Choosing the user's labels

`VoiceFilter` is a pure function in `Shared/Core` from the attributed phrases,
one embedding per label and the profile to the set of user labels:

1. With fewer than two labels, deliver `text` unchanged.
2. A label's evidence is its speech spans, up to the model's 10 s window and
   longest spans first. A label with under 0.5 s of speech is too short to judge
   and is kept.
3. The **anchor** is the label that best matches a ready profile. If even that
   score is below the presence floor, the user is not recognizably in the
   recording, for example someone else dictating, and everything is kept.
   Without a ready profile, the first-speaking and the most-words labels both
   anchor.
4. Every other label is kept when its embedding matches an anchor's embedding
   from the same recording at the same-speaker threshold, and dropped
   otherwise. The stored profile does not keep labels: other people scored up to
   0.49 against it while the user's own muffled label scored 0.29.
5. Deliver the kept phrases joined by a space, even when every label is kept.
   The combined `text` is the same phrases, but the model writes line breaks at
   some speaker changes, which would split the user's own sentence when
   diarization gives the user two labels. Azure phrases are sentences with
   their own capitalization and punctuation, so the seams need no repair.

The starting values are a same-speaker threshold of 0.5, the middle of the
measured gap, and a presence floor of 0.25. Validation sets both, and they are
the only tunable values.

### Embeddings

`SpeakerEmbedder` is an actor that owns one Core ML model: WeSpeaker
ResNet34-LM (256 dimensions, CC-BY-4.0 weights) with its filterbank front end.
A checked-in uv script converts the upstream checkpoint to an `.mlpackage`, so
the model's provenance, license and version are owned. Core ML runs on both
floors and both platforms. Core AI waits until a measurement shows a gain.

- Input is the 16 kHz PCM16 the provider received. The batch paths already
  hold it, and the live path decodes the finished original with
  `OriginalAudio.providerWAV`, so every path scores the same audio.
- All labels go into one batched call, with each label's speech masked into
  its window.
- The model loads when a dictation session starts with Only mine on and
  unloads when the session ends or on memory pressure, so a dictation pays no
  load cost.
- Compute units are the CPU and the Neural Engine. The iOS app requests the
  background inference entitlement, unless the first measurement shows CPU-only
  meets the budget, which would avoid a capability change.
- The model is bundled in both containing apps, not the keyboard. At about
  15 MB it does not justify Background Assets, which would also leave out the
  Developer ID Mac.

### Voice profile

`VoiceProfile` is a value holding up to 24 exemplar embeddings and the model
version that produced them. `VoiceProfileStore` keeps it as one Keychain item
per verified account, with `AfterFirstUnlockThisDeviceOnly`, no
synchronization, and the containing app's own access group (on the Mac, the
data-protection keychain).

- **Learning** is silent. After delivery, a dictation with exactly one label and
  at least 5 s of speech adds one exemplar from up to 10 s of that speech.
- **Ready** means three exemplars that agree with each other (pairwise mean of
  at least 0.5). Until then, the first and most-words labels anchor. Early
  exemplars that disagree are replaced by later ones until three agree, so one
  dictation by someone else cannot define the profile.
- **Updates** after that accept an exemplar only when it matches the profile,
  using the mean of its three best matches, at the same-speaker threshold. A
  full profile replaces its most redundant exemplar, keeping variety across
  microphones and rooms.
- **Deletion** happens on Forget My Voice, on switching to Everyone, on an
  account change, and when the model version changes. Learning starts again
  from the next dictations.

The profile is derived state with one owner. It is small (about 25 KB), never
written to the dictation library, and the filter and learning code only see
values passed into them.

### Results

The `providerOutput` result version keeps the provider's full `text`. SpeechKit
gains an optional `voices` field on `DictationResultVersion`: the attributed
phrases with their spans and the user labels this device chose. The delivered
text is derived from them, and a result without `voices` delivers `text` as
before. Results travel as an encrypted JSON payload, which older clients store
byte for byte and decode while ignoring unknown keys. The field therefore needs
no CloudKit schema change and breaks no installed version. Older versions show
the full text in history.

A new `DictationResultKind` would be simpler to read but would break old
clients, because an unknown kind fails decoding for the whole capture.

Transcribe Again records a new result with the current setting and profile.
`SharedHistoryProjection` and `HistoryEntry.text` use the delivered text.

### Setting and history

- Settings has a Voices picker, Only Mine or Everyone, synced through KVS like
  other preferences, and a Forget My Voice button while Only Mine is selected.
  The profile itself never syncs; each device learns its own microphone.
- A history entry that dropped speech shows the removed phrases behind an
  "Other voices" disclosure, with Copy Everything. Nothing changes in the
  keyboard or onboarding.

### Failure behavior

Any failure, such as the model failing to load, inference throwing, an
unreadable original or a malformed `phrases`, delivers the full `text`, writes
the result without `voices`, and reports a `DiagnosticError` under the
`voice_filter` category. The filter can delay delivery but never blocks or
empties it.

Diagnostics carry the label count, dropped label count, decision path (profile,
fallback, kept everything) and timing. They never carry embeddings, scores or
text.

### Privacy

`PRIVACY.md` gains a paragraph on the on-device voice profile: what it is, that
it never leaves the device, and how to delete it. Apple's privacy label counts
only data that leaves the device, so the label is unchanged; the maintainer
confirms both before release. Provider responses add speaker labels and
timings, which carry nothing beyond the transcript Azure already returns.

## Performance budget

| Step | Single voice | Several voices |
| --- | --- | --- |
| Azure diarization and word timestamps | about +0.4 s (measure) | same |
| Decode the original | none | about 10 ms for 30 s (measure) |
| Embedding, warm, batched | none | under 50 ms on the Neural Engine (measure) |
| Profile learning | after delivery, one window | none |

## Alternatives considered

- **Most words, or first and most words, as the only rule.** No model ships,
  but the first is unsafe and the second leaks TV and interjections. The second
  stays as the fallback until a profile is ready.
- **A fixed voiceprint threshold.** Simple, but microphone and room mismatch
  drops the user.
- **An explicit "teach your voice" step.** Clearer consent, but more friction,
  and recordings made with intent sound unlike real dictations. Silent learning
  with a visible Forget control is proposed instead; the maintainer decides.
- **FluidAudio or sherpa-onnx as a dependency.** Ready-made, but FluidAudio
  changed four times in a month, its model terms differ from the upstream
  checkpoint, and sherpa-onnx runs ONNX Runtime on the CPU only. One owned
  conversion and a small Core ML wrapper are less code to trust.
- **CAM++ or ReDimNet2.** CAM++ is cheaper on the CPU and ReDimNet2 more
  accurate, but CAM++'s Core ML port was fixed five days before this decision,
  and the best ReDimNet2 weights forbid commercial use. ResNet34-LM keeps the
  embedding space the evidence was measured in.
- **Target-speaker extraction such as VoxLock.** It removes overlapped TV
  speech, but costs about 80 MB and does not run in real time. Revisit it after
  this ships.
- **Splitting labels into pieces at pauses.** It handles one label holding two
  people, but adds several thresholds for a case the evidence did not show.

## Assumptions that could invalidate the design

1. Diarization on the progressive upload costs about 0.4 s. If it costs much
   more, Only Mine needs another trigger, such as on-device diarization.
2. Embedding fits the budget in the background on the iPhone 14 Plus, with the
   inference entitlement or on the CPU.
3. The same-speaker gap (0.45 against 0.84) holds for fresh recordings,
   Swedish speech and the Mac microphone. Both thresholds were picked after
   seeing the data.
4. MAI-Transcribe-2 keeps splitting phrases at speaker changes, so a phrase
   rarely mixes two people outside overlap.
5. The converted and quantized model scores like the reference model.

If assumption 3 fails, the cost is a threshold change. If assumption 1 or 2
fails, the trigger or the model changes, but the protocol, filter shape,
storage and UI stay.

## Validation and slices

1. **Prototype measurement**, in parallel with the next two slices: convert
   the model, then measure load, latency and memory on the iPhone 14 Plus in
   the foreground and background, on the CPU and the Neural Engine, with and
   without the entitlement. Compare scores with the reference model on the
   private corpus.
2. **SpeechKit**: the optional `voices` field, released and pinned.
3. **Access service**: the `voices` start field, the reply `phrases` and the
   response cap. `just test-access-live` gains a synthetic two-voice fixture
   asserting two labels with spans, and reports the latency and size deltas.
4. **App**: `VoiceFilter`, `SpeakerEmbedder`, `VoiceProfileStore`, wiring in
   both coordinators and Transcribe Again, settings and history UI, Swedish
   strings, `PRIVACY.md` and `THIRD_PARTY_NOTICES.md`. Swift Testing covers the
   filter with fixed embeddings, including the split-label, TV-ad and
   someone-else-dictating cases. The live gate runs the real stream, filter and
   bundled model against the two-voice fixture and asserts the second voice is
   dropped.
5. **Default on** only after a fresh private set, recorded after this design,
   shows no lost user words. Leaked words per minute are reported beside it.
