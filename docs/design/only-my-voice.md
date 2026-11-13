# Only Mine

Mumla defaults to Only Mine and learns its voice profile on the device. The
engine, its model, rules, calibration and profile persistence are owned by
SpeechKit's optional `SpeakerRecognition` product; see the
[speaker recognition design](https://github.com/emileberhard/SpeechKit/blob/0.8.0/docs/speaker-recognition.md).
Mumla owns the setting, access protocol, account partition, synced forget date,
status wording, diagnostics and where everyone's text is retained.

`AccessStream` decodes the service's `[offsetMs, durationMs]` word pairs into
`SpeechKit.SpeakerPhrase` with typed ranges from audio start. The live session
feeds a `VoiceCheck`, sends `finish` to the service, then lets the check request
labels: at once when its watcher asks, otherwise after the plain result when
that transcript marks another speaker. The callback receives the admitted PCM16; Mumla ignores that argument
because the access service already holds the audio. It resolves the plain result
with an added wait of 4 seconds plus 5 milliseconds per second of admitted audio,
capped at 6 seconds. Batch transcription uses the same package's one-shot filter and does not relearn replayed audio. Cancellation
before delivery prevents handoff; teardown after delivery allows learning.
Account changes retire the previous store before replacing it. Forget My Voice
continues to sync `voiceForgottenAt`; earlier checks cannot filter or learn.

### Recognition and learning

With a trusted profile, the package watches voiced pieces and overlapping
2-second windows every second. It requests labels when a piece or window
matches the profile at 0.35 and either the piece detector fires or at least two
windows score below 0.20 against the profile. A coherent mismatch alone cannot
request a check with no recognizable owner. If the watcher is still checking
when the ordinary transcript arrives, everyone's text is delivered immediately.

MAI-Transcribe-2 breaks the plain transcript's line where it hears another
speaker, so Mumla tells the package that its lines are speaker turns. A second
line with words requests labels even when the watcher heard nothing, which
catches a remark too short for the watcher.

A label's duration is the length of its merged word spans, including gaps of up
to 150 milliseconds. A label shorter than 1 second is never judged by its
audio: it is dropped only when the plain transcript marked another speaker and
the user is recognized in the same recording, and kept otherwise. A 1–2-second
label can anchor only at 0.50 against the profile and can be dropped only below
0.25 against both the profile and the recording's anchor. Labels of at least
2 seconds retain the 0.35 anchor and rejection bars. Doubt, an empty labelled
reply or no dropped label keeps the caller's original transcript.

Learning requires a transcript with words that marks no other speaker and at
least 5 seconds of speech. A silent recording once counted as a trust miss and
switched filtering off. Learning also always passes the standalone
coherence gate: the existing piece rule, or two supported windows below 0.05
against each other, identifies mixed voices. Each supported window must match
another window at 0.50. A labelled reply can only withhold learning: more than
one attributed speaker or any dropped label teaches neither exemplars nor trust
observations. A single-speaker reply cannot override mixed-voice evidence.
Profile mismatch alone never vetoes learning, so coherent misses can still
reset a wrong profile. Batch replay does not learn the recording again.

Recognition admits at most 600 seconds of audio. Beyond that bound it discards
its recognition audio, does not request labels, filter a prefix or learn; normal
capture and transcription continue. The service's separate retained-audio cap
also remains in force.

### Service

The `start` message has an optional `speakers` field with two explicit
modes:

- `"onRequest"`, for live capture. The request to Azure stays exactly as
  today, and the service also keeps the stream's audio in memory. After
  `finish`, a single `{"type": "voices"}` message starts a second Azure
  request on that audio, with `diarization: {enabled: true}` and
  `timestamps: "word"`. The service replies with today's `result`, then with
  `{"type": "voices", "text", "phrases"}`. The socket closes 5 s after `result`
  if no `voices` message arrives, which leaves room for the app to ask once it
  has read the result.
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

Mumla maps the original error through `DiagnosticError`, with a
public stage of `filter` or `learning`. The existing `voice_filter` values remain
`not_heard`, `too_long`, `undecided`, `kept_everyone`, `filtered` and `failed`,
with `voice_labels` and `voice_labels_dropped` counts. Every attempted live
check also records `voice_labels_reply_ms`, including failures and timeouts,
and `voice_labels_at_turn` when the transcript's line break, not the watcher,
requested the labels.
No diagnostic includes text, embeddings or similarity scores. A failure keeps
everyone's text and does not teach the profile.

The live gate (`just test-access-live`) streams a synthetic two-voice mix
through the real session, package watcher, service and filter with a trusted
synthetic profile, then diarizes the same mix in a batch request. Both must
drop the second voice and retain the first, and the first stream's labels must
be requested by the watcher. A third stream adds a 0.9-second remark by the
second voice that the watcher does not hear: the plain result's line break, not
the watcher, must request the labels and the remark must be dropped. The
provider's line break is observed behaviour, not a contract, and a synthetic
clip does not always get one (the probe's Opus round trip alone changed it for
one clip), so that stream repeats, at most three times, only while the plain
result has no line break; a result with one must pass. Wire decoding and lifecycle
regressions stay in Mumla; model and policy tests live in SpeechKit.

### Calibrated delivery budget

The budget `min(6 s, 4 s + 5 ms per second of audio)` is calibrated for the
access service's retained-audio transport. Across 67 fresh labelled requests,
the median reply was 1.589 seconds, p95 3.538 seconds and maximum 6.442 seconds.
The budget covered 65 of 67 replies; two tail replies intentionally time out
and deliver everyone. The package's design records the calibration's bounds
and remaining short-interjection misses. Numeric `voice_labels_reply_ms`
measurements accompany the existing decision metadata on every attempted
live check so this policy can be checked against real traffic.
