# Only my voice

Status: proposed after two independent challenges. The validation at the end
sets the thresholds and gates the release.

With Only Mine selected, a dictation contains only what the dictating user
said; other people in the room, a TV and a phone on speaker are left out.
Everyone transcribes everything, exactly as today. Transcription stays with
Azure MAI-Transcribe-2 through the [access service](mumla-access-service.md);
recognizing the user's voice happens on the device.

## Goals and constraints

- Feel like today. A dictation with one voice, nearly all of them, is
  delivered with today's request, text and latency. Only a dictation where
  another voice was heard may take a little longer.
- Never lose the user's own words. When the evidence is unclear, keep the text:
  a leaked "Yeah?" costs less than a missing sentence.
- The voice profile is a biometric template. It never leaves the device: no
  CloudKit, KVS, iCloud Keychain, device backup, App Group, diagnostics or
  service.
- Works on the iOS 26 and macOS 26 floor, tuned for iOS 27.2 and Apple silicon.
- Old app versions keep reading everything new versions write.
- Out of scope: speech that overlaps the user's own, such as a TV under the
  user's voice. Diarization merges it into the user's label, and only
  target-speaker extraction separates it.

## Evidence

A small model screened 5,248 of the maintainer's recent transcripts for
possible background speech. Diarizing the 67 strongest candidates found two or
more speaker labels in 20. In one of them, both labels were the user: the phone
lay on fabric and the voice changed. The recordings, transcripts and scores
stay outside the repository; this document records only aggregates.

**Rules without a voice model lose the user's words.** Keeping the label with
the most words dropped the user in 2 of 20 recordings, and keeping the first
and the most-words labels dropped the user in 1. Another label was louder than
the user's in 6 of 20.

**Speaker models, compared on the same recordings and the same word spans**
(Core ML timings on an M1 Max, an older Neural Engine than current iPhones):

| Model | User's label found | Same-voice margin | Neural Engine, 10 s | CPU, 10 s | Size |
| --- | --- | --- | --- | --- | --- |
| WeSpeaker ResNet34-LM | 19 of 19 | +0.23 | 6 ms | 20 ms | 6.7 MB (8-bit) |
| ReDimNet2-B3 | 19 of 19 | +0.37 | 105 ms | 88 ms | 8.8 MB |
| WeSpeaker CAM++-LM | 19 of 19 | +0.10 | did not compile | 18 ms | 15 MB |
| ECAPA, TitaNet, ERes2Net | 19 of 19 | +0.05 to +0.21 | not converted | | 26–101 MB |

The margin is the gap between the user's own second label and the closest other
person, both scored against the user's main label in the same recording.
ResNet34-LM runs 101 of its 102 operations on the Neural Engine. ReDimNet2's
long depthwise convolutions fall back to the CPU there.

With ResNet34-LM and mean normalization:

- **Labels of 2 s or more:** 95% of the user's own labels scored at least 0.32
  against the user's other speech in the same recording. Other people scored at
  most 0.24 there, and at most 0.26 against the enrolled voice. One recording
  holds four 2–4 s pieces of the user's label that fail both checks; it needs
  listening before calibration, since its label may contain another voice.
- **Pieces under 1 s are not judgeable:** the user's own short pieces scored as
  low as 0.06.

**Latency**, from 67 recordings, three variants and three runs each, in random
order:

| Azure request | Median | Added |
| --- | --- | --- |
| Today's request | 210 ms | |
| With word timestamps | 230 ms | +6 ms per recording |
| With diarization and word timestamps | 530 ms | +308 ms per recording, +166 to +871 |

Diarization costs about 0.3 s at every length, so requesting it for every
dictation would slow every dictation down.

**Detecting another voice on device**, before any diarization: the
recordings are split at pauses into pieces of 1–10 s, and each piece is
compared with the pooled rest of the recording. That flagged 6 of the 7
recordings where another voice spoke long enough to judge. False alarms on
single-voice recordings were 0 of 15 under 30 s and 3 of 11 over 30 s.
Comparing every pair of pieces instead flagged 9 of those 11 longer recordings,
because more pieces make one low pair likely. Brief interjections, and voices
sharing a piece with the user, go undetected. They leak, but never cost the
user's words.

Platform facts, checked 2026-11-06:

- Azure diarization labels speakers anonymously per phrase. Azure has no speaker
  identification (Speaker Recognition is retired) and no target-speaker option.
- No Apple framework in the iOS 27.2 SDK offers speaker embeddings,
  identification or diarization. Voice Isolation keeps every voice.
- iOS 27 and macOS 27 require
  `com.apple.developer.background-tasks.continued-processing.inference` for
  Neural Engine use in the background, on Apple Intelligence devices. The
  keyboard flow and the Mac menu-bar app both dictate in the background.

## Design

```
capture ──┬── PCM ──▶ access stream (today's request; the service keeps the audio)
          └── PCM ──▶ voiced pieces ──▶ embeddings ──▶ another voice heard?
stop ──▶ no:  deliver text, then learn from the dictation
         yes: the service diarizes the kept audio ──▶ choose the user's labels ──▶ deliver
```

### While capturing

`VoiceWatch` is an actor fed the same 16 kHz PCM the provider receives. It
cuts voiced audio into pieces at pauses, capped at 10 s, and embeds each piece
of at least 1 s as it ends. Each piece costs one model call on the CPU, about
12 calls per minute of speech, or roughly 0.4% of one core. That keeps the work
background-safe and finished by the time the user stops.

Another voice is heard when a piece scores below the detection threshold
against the duration-weighted mean of all the other pieces. At stop, at most
one piece is still open, so the answer normally arrives while Azure is still
transcribing. An answer that isn't ready when the first result arrives counts
as not heard, so the watcher can never delay delivery.

`VoiceWatch` runs only when Only Mine is selected and the profile is ready.
Before that, nothing is filtered, so nothing needs detecting. Batch recovery of
a capture reuses the answer its watcher gave.

### Service

The `start` message gains an optional `speakers` field with two explicit
modes:

- `"onRequest"`, for live capture. The request to Azure stays exactly as
  today, and the service also keeps the stream's audio in memory. After
  `finish`, a single `{"type": "voices"}` message starts a second Azure
  request on that audio, with `diarization: {enabled: true}` and
  `timestamps: "word"`. The service replies with today's `result`, then with
  `{"type": "voices", "text", "phrases"}`. The socket closes 5 s after `result`
  if no `voices` message arrives.
- `"diarize"`, for Transcribe Again and for batch recovery when the watcher
  heard another voice. The one Azure request is diarized and the reply is the
  `voices` form. No audio is kept.

Each phrase carries its integer `speaker`, its `text`, and its words as
`[offsetMs, durationMs]` pairs without word text. Grouping words into spans is
the app's decision, not the service's. Either reply can deliver the dictation
on its own.

Rules for the kept audio and the second request:

- **Limits:** the kept audio is capped at 10 minutes per stream, and at a
  global byte budget across streams. Past either limit, the service answers
  `voices_unavailable` from the start, and the app delivers everyone.
- **Billing:** the second request is not charged to the user's allowance,
  because the grant already covers the audio. It doubles the Azure cost of the
  few dictations that use it. A failure answers `voices_unavailable`, also
  uncharged.
- **Deploys:** the deploy drain counts a pending second request as live work.
- **Compatibility:** without the field, every byte of request and reply stays
  as today. Transcript text and word timings stay out of service logs.

Price this first: if Azure does not bill an upload that is aborted before its
body ends, the service can instead stream a diarized request alongside the
plain one from the start, and abort it at stop when no voice was heard. That
deletes the kept audio and its limits, and saves the re-upload. One billing
check decides which version is built.

### Choosing the user's labels

`VoiceFilter` is a pure function in `Shared/Core`. Its inputs are the
diarized phrases, one embedding per label and the profile; its output is the
labels to keep.

1. A label's evidence is its own speech: its word spans, padded and
   concatenated, longest first, up to the model's 10 s window, and tiled when
   shorter. On iOS the provider PCM is still in memory at this point; the macOS
   live path decodes the finished original.
2. A label with under 2 s of speech is kept unjudged.
3. The **anchor** is the judged label that best matches the profile. If no
   judged label reaches the same-voice threshold against the profile,
   everything is kept: the user is not recognizably there, or diarization split
   them into fragments.
4. Any other judged label is dropped only when two references reject it: the
   anchor's speech from the same recording, and the profile. A label matching
   either one at the same-voice threshold is kept. The same-recording check
   rescues the user's own voice when a change in microphone or room confuses
   the profile; the profile rescues it when diarization splits the user
   unevenly.
5. If nothing is dropped, which is the case on a false alarm, the first
   request's text is delivered, so a false alarm costs latency but never
   changes the text. Otherwise the kept phrases are joined by a space. The
   combined `text` is the same phrases, but with line breaks the model inserts
   at some speaker changes. Phrases are speaker turns, so dropping an
   interruption can leave the turn before it without closing punctuation; that
   is accepted.

Starting values: a same-voice threshold of 0.3 and a detection threshold of
0.35, both on mean-normalized ResNet34-LM embeddings. Detection may sit higher
because a false alarm costs only a rerun. Calibration sets both, judged by how
often the user's own speech fails both checks, not by each check alone. They
are the only tunable values.

### Embeddings

`SpeakerEmbedder` owns one Core ML model: WeSpeaker ResNet34-LM, 256
dimensions, CC-BY-4.0 weights, a fixed 10 s input, mean normalization inside
the model, 8-bit palettized to 6.7 MB. A checked-in uv script converts the
upstream checkpoint and verifies the result against PyTorch (cosine ≥ 0.999).
The script's output, the compiled model and its SHA-256 are committed together.
Pieces shorter than the window are tiled; tiling moved the measured margins by
at most 0.01.

- The Kaldi filterbank (80 bins, 25 ms window, 10 ms hop) is computed in Swift
  with Accelerate in fp32, checked against fixtures from the reference.
- Inference runs on the CPU everywhere: about 20 ms per window, background-safe
  on both platforms, with no new entitlement. The Neural Engine is about three
  times faster. If device measurements show the CPU misses the budget, the iOS
  app adds the background inference entitlement, which reissues its profiles.
- The model loads when a capture starts with Only Mine ready, which hides its
  load time behind the first second of speech. It unloads after delivery and
  learning.
- It is bundled in both containing apps and not in the keyboard. Background
  Assets would not reach the Developer ID Mac and is not needed at this size.
- Core AI is skipped: it is iOS 27 and later only, and Core ML reaches the same
  Neural Engine on both floors.

### Voice profile

`VoiceProfile` is a value holding up to 24 exemplar embeddings and the model
version that made them. `VoiceProfileStore` keeps it in one file of about 25 KB
in the verified account's `Accounts/<SHA256>` partition, never in the
unconfirmed one. The file is excluded from backup, uses
`completeUntilFirstUserAuthentication`, and is never added to an outbox. Each
account's profile stays dormant while another account is signed in. The file
goes away when the app is uninstalled.

- **Learning** uses dictations where no other voice was heard and there are at
  least 5 s of speech. After delivery, one embedding of up to 10 s of speech
  becomes a candidate.
- **Ready** requires five candidates that each reach the learning threshold
  against the mean of the other four. The learning threshold is stricter than
  the same-voice threshold, starting at 0.5. A candidate that fails is dropped,
  so one dictation by someone else delays readiness without defining the
  profile. A device shared by two people who dictate equally rarely becomes
  ready, and then filters nothing. Calibration measures how many dictations
  readiness takes.
- **Updates** accept a candidate whose mean of its three best matches reaches
  the learning threshold. The profile freezes at 24 exemplars, so it cannot
  drift and stops costing work.
- **Deletion** happens on Forget My Voice and when the model version changes;
  learning then starts again. Selecting Everyone stops using and learning the
  profile but keeps it. Because the setting syncs, a choice on one device must
  not wipe the others.

### Results and history

`text` stays the delivered transcript everywhere, so search, the `mumla`
CLI, agent tools, history matching and older app versions all read what the
user received, with no reader changes. When voices were dropped, the
complete transcript goes into a new optional `unfilteredText`:

- on `HistoryEntry`, as an additive CloudKit field deployed through the
  [schema procedure](../cloudkit-schema.md);
- on SpeechKit's `DictationResultVersion`, when recordings are saved to the
  library. Results travel as an encrypted JSON payload, which older clients store
  byte for byte and decode while ignoring unknown keys.

SpeechKit's outbox publication currently re-encodes results. It must publish
the stored bytes instead, so a downgraded install cannot strip the field and
then hit `contentConflict`. That fix ships one release before the first release
that writes the field. A new `DictationResultKind` was rejected, because
one unknown kind fails the whole archive listing on older clients.

Transcribe Again follows the current setting and profile, with one diarized request.

### Setting and history UI

- **Default:** Only Mine is the default for new and existing users, and the
  profile learns silently from ordinary one-voice dictations; there is no
  consent step (maintainer decision, 2026-11-06). The profile never leaves the
  device, `PRIVACY.md` describes it, and Forget My Voice deletes it. The
  choice syncs through KVS, so it applies on all of the user's devices.
- **Settings:** a Voices picker (Only Mine, Everyone) and Forget My Voice.
- **History:** an entry with `unfilteredText` shows that other voices were left
  out, with Show Everyone and Copy Everything.
- **Elsewhere:** nothing changes in the keyboard.

### Failure behavior

Any failure delivers everyone's text and reports a `DiagnosticError` under
`voice_filter`. Failures include the model failing to load, inference
throwing, `voices_unavailable`, a malformed reply, or the diarized reply
missing the 2 s deadline after the plain result. Recordings over 10 minutes
always take this path. The filter can delay delivery
by at most that deadline; it never blocks or empties delivery.

Diagnostics carry counts (pieces, labels, dropped labels), the decision path
(not heard, filtered, kept everything) and timing. They never carry
embeddings, scores or text.

### Privacy

`PRIVACY.md` gains three statements:

- the on-device profile: what it is, that it never leaves the device, and how
  to delete it;
- that the provider may be asked to separate speakers;
- that the service holds a stream's audio in memory until the stream ends.

The App Store label counts only data that leaves the device, so it is
unchanged; the maintainer confirms both. Bundling the CC-BY-4.0 weights adds
their attribution to `THIRD_PARTY_NOTICES.md` and `LICENSES/`.

## Latency budget

| Dictation | Added at stop |
| --- | --- |
| One voice (nearly all) | the last open piece, overlapped with Azure; nothing expected |
| Another voice heard | about +0.3 s for diarization, plus 2–3 embeddings (about 60 ms on CPU) |
| False alarm (0 of 15 under 30 s, 3 of 11 over) | the same, then today's text |

## Alternatives considered

- **Diarize every dictation.** Simplest service change, and Azure groups even
  brief interjections, but it costs every dictation 0.3 s.
- **Diarize on device** with a segmentation model. No Azure diarization at
  all, but it adds a second model and clustering, and its accuracy relative to
  Azure is unmeasured. Revisit it if reruns turn out frequent.
- **Most words, first speaker, loudest.** No model, but each loses the user in
  the evidence.
- **ReDimNet2-B3.** Better margin, but 105 ms per window, too slow for capture
  and the background.
- **FluidAudio or sherpa-onnx as dependencies.** Ready-made, but FluidAudio
  changed four times in a month and sherpa-onnx's pipeline skips WeSpeaker's
  mean normalization. That alone cut its short-piece rejection from 25 of 36 to
  5 of 36. One owned conversion is less to trust.
- **Keychain storage.** Not synced, but its items survive uninstall and are
  restored from device backups.
- **Asking before learning.** Choosing Only Mine as the consent, in onboarding
  and on a one-time card, is the conservative reading of GDPR and Illinois
  BIPA for voice templates. The maintainer chose silent learning: the template
  is on-device only, Apple's privacy definitions count as collected only data
  that leaves the device, and Forget My Voice deletes it.
- **Target-speaker extraction (VoxLock).** It handles overlap, but at about
  80 MB and slower than real time. Revisit it later.

## Assumptions that could invalidate the design

1. The same-voice and detection thresholds hold on fresh, random dictations,
   on Swedish, and on the Mac microphone. Both were fitted on 19 screened
   recordings. If they fail, only thresholds change.
2. CPU embedding fits the budget on the iPhone 14 Plus, the M1 iPad and macOS
   27 in the background. If it doesn't, the iOS app adds the inference
   entitlement.
3. The detector's false alarms stay rare on long dictations, and its misses
   are mostly brief. If either fails, diarize every dictation and accept the
   0.3 s.
4. Keeping up to 10 minutes of audio per stream fits the service's memory at its
   real concurrency.
5. Diarization is not billed above transcription.

## Slices and validation

1. **Prototype measurement.** Convert the model, port the filterbank, and
   measure load, latency and memory on the iPhone 14 Plus, the M1 iPad and macOS
   27, in the foreground and the background, with another app in front.
2. **Calibration set.** Diarize a random sample of about 300 ordinary
   dictations, with word timestamps, including Swedish and Mac recordings.
   From it, measure how often Azure splits one user, draw same-voice pairs, run
   the detector, and set both thresholds. Report the detector's false alarms by
   dictation length, how often the user fails both checks, the dictations
   readiness takes, the set's size and the rule-of-three bound.
3. **SpeechKit.** Publish stored bytes and ship that in an app release first,
   then add `unfilteredText`; release and pin.
4. **Access service.** First check Azure billing for aborted uploads, then
   add the `speakers` modes and the `voices` reply. Service unit tests cover the
   limits, `voices_unavailable` and the drain. `just test-access-live` drives
   `voices` after `finish` through the real `AccessStream` on a synthetic
   two-voice fixture, asserting two labels with word timings, plus a long
   fixture for the response cap. Older services reject the new field, so the rollback floor is
   this version; record it in the service README.
5. **App.** Add `VoiceWatch`, `VoiceFilter`, `SpeakerEmbedder`,
   `VoiceProfileStore`, settings and history UI, `unfilteredText` on `HistoryEntry` with its
   schema deploy, and Swedish strings. A test checks that an older build
   re-saving a history record keeps the new CloudKit field. Update
   `PRIVACY.md`, the notices, this repository's agent instructions,
   `mumla-access-service.md`, `unified-dictation.md` and
   `library-agent-tools.md`. Swift Testing covers the filter with fixed
   embeddings: a split user, a TV ad, someone else dictating, labels under
   2 s and no ready profile. The live gate runs the real stream, watcher, filter
   and bundled model against the two-voice fixture with a synthetic ready
   profile, and asserts the second voice is dropped.
6. **Release** after a fresh private set, recorded after this design, loses no
   user words. Leaked words per minute and the rerun rate are reported beside it.
