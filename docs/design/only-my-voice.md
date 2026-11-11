# Only Mine

Mumla defaults to Only Mine and learns its voice profile on the device. The
engine, its model, rules, calibration and profile persistence are owned by
SpeechKit's optional `SpeakerRecognition` product; see the
[speaker recognition design](https://github.com/emileberhard/SpeechKit/blob/feat/speaker-recognition/docs/speaker-recognition.md).
Mumla owns the setting, access protocol, account partition, synced forget date,
status wording, diagnostics and where everyone's text is retained.

`AccessStream` decodes the service's `[offsetMs, durationMs]` word pairs into
`SpeechKit.SpeakerPhrase` with typed ranges from audio start. The live session
feeds a `VoiceCheck`, sends `finish` to the service, then lets the check request
labels. It resolves the plain result with an added wait of 4 seconds plus
5 milliseconds per second of admitted audio, capped at 6 seconds. Batch transcription uses the same
package's one-shot filter and does not relearn replayed audio. Cancellation
before delivery prevents handoff; teardown after delivery allows learning.
Account changes retire the previous store before replacing it. Forget My Voice
continues to sync `voiceForgottenAt`; earlier checks cannot filter or learn.

### Service

The `start` message has an optional `speakers` field with two explicit
modes:

- `"onRequest"`, for live capture. The request to Azure stays exactly as
  today, and the service also keeps the stream's audio in memory. After
  `finish`, a single `{"type": "voices"}` message starts a second Azure
  request on that audio, with `diarization: {enabled: true}` and
  `timestamps: "word"`. The service replies with today's `result`, then with
  `{"type": "voices", "text", "phrases"}`. The socket closes 5 s after `result`
  if no `voices` message arrives.
- `"diarize"`, for Transcribe Again and batch recovery. The one Azure request
  is diarized and the reply is the `voices` form. No audio is kept.

Each phrase carries its integer `speaker`, its `text`, and its words as
`[offsetMs, durationMs]` pairs without word text. The app translates these pairs to typed spans; the package owns evidence
grouping. Either reply can deliver the dictation
on its own. When Azure's phrases are unusable, `onRequest` answers
`voices_unavailable` and `diarize` answers the plain `result`, so the text
always arrives.

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

### Results and history

`text` stays the delivered transcript everywhere, so search, the `mumla`
CLI, agent tools, history matching and older app versions all read what the
user received, with no reader changes. When voices were dropped, the
complete transcript goes into a new optional `unfilteredText` on
`HistoryEntry`. In this first release it stays local: the shared-history
projection carries it across rebuilds, but it has no CloudKit field.

The next release syncs it:

- on `HistoryEntry`, as an additive CloudKit field deployed through the
  [schema procedure](../cloudkit-schema.md);
- on SpeechKit's `DictationResultVersion`, when recordings are saved to the
  library. Results travel as an encrypted JSON payload, which older clients store
  byte for byte and decode while ignoring unknown keys.

SpeechKit 0.2.3, pinned in the first release, publishes stored result bytes
instead of re-encoding them, so a downgraded install cannot strip the field and
then hit `contentConflict`. A new `DictationResultKind` was rejected, because
one unknown kind fails the whole archive listing on older clients.

Transcribe Again follows the current setting and profile, with one diarized
request, and writes its history row with everyone's words as it records the
result.

### Setting and history UI

- **Default:** Only Mine is the default for new and existing users, and the
  profile learns silently from ordinary one-voice dictations, earlier ones
  still on the device included; there is no
  consent step (maintainer decision, 2026-11-06). The profile never leaves the
  device, `PRIVACY.md` describes it, and Forget My Voice deletes it. The
  choice syncs through KVS, so it applies on all of the user's devices.
- **Settings:** a Voices picker (Only Mine, Everyone), the profile's status
  (Learning or Learned, which means trusted) and Forget My Voice.
- **History:** an entry with `unfilteredText` shows that other voices were left
  out, with Show Everyone and Copy Everything.
- **Elsewhere:** nothing changes in the keyboard.

### Privacy

`PRIVACY.md` describes the on-device profile, that it never leaves the device
and how to delete it; that the provider may be asked to separate speakers; and
that the service holds a stream's audio in memory until a few seconds after
its transcript. Both microphone purpose strings say that Mumla recognizes the
user's voice on the device. The App Store label counts only data that leaves
the device, so it is unchanged. Bundling the CC-BY-4.0 weights adds
their attribution to `THIRD_PARTY_NOTICES.md` and `LICENSES/`.

### Account and history

The app supplies its verified account's isolated `Accounts/<SHA256>` directory
to `VoiceProfileStore`; unconfirmed accounts have no voice store. Profiles are
excluded from backup and never enter a sync outbox. `VoiceProfiles` applies the
synced forget date before loading, displaying or using a profile. The app
fetches only local-original metadata and supplies `OriginalAudio.pcm16` as the
history decoder. The package owns history eligibility, ordering and trust;
the app cancels history work when its partition changes.

### Diagnostics

Mumla maps `VoiceCheckFailure.underlying` through `DiagnosticError`, with a
public stage of `filter` or `learning`. The existing `voice_filter` values remain
`not_heard`, `too_long`, `undecided`, `kept_everyone`, `filtered` and `failed`,
with `voice_labels` and `voice_labels_dropped` counts. Every attempted live
check also records `voice_labels_reply_ms`, including failures and timeouts.
No diagnostic includes text, embeddings or similarity scores. A failure keeps
everyone's text and does not teach the profile.

The live gate (`just test-access-live`) streams a synthetic two-voice mix
through the real session, package watcher, service and filter with a trusted
synthetic profile, then diarizes the same mix in a batch request. Both must
drop the second voice and retain the first. Wire decoding and lifecycle
regressions stay in Mumla; model and policy tests live in SpeechKit.

### Calibrated delivery budget

The budget `min(6 s, 4 s + 5 ms per second of audio)` is based on 54 fresh
labelled requests. Under 15 seconds of audio, the median was 0.87 seconds and
the maximum 1.61; for 15–60 seconds, 1.60 and 2.65; for 60–120 seconds, 1.93
and 2.60; for 120–600 seconds, 2.33 and 2.91. The minimum also covers the
previously observed 2.165-second reply. Numeric `voice_labels_reply_ms`
measurements accompany the existing decision metadata on every attempted
live check so this transport policy can be checked against real traffic.

Three later serial requests took 3.83 seconds for 10.4 seconds of audio, 1.25
for 27.4, and 6.44 for 86.9. The final 4-second base covers 57 of the 58
measured replies and fails open on the 6.44-second outlier; the earlier
3-second base covered 56 of 58.
