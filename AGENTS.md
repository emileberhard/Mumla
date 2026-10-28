# Mumla

Mumla is voice-to-text for macOS and iOS: a macOS menu bar app, an iOS
containing app, and an iOS keyboard extension that dictates through it. Ship
small, correct changes that preserve the dictation UX, keyboard reliability,
the release pipeline and the shared `SpeechKit` integration. `CLAUDE.md` is a
symlink to this file; it is the canonical agent context for the repository.

## Public repository

This repository is public and source-available under PolyForm Shield 1.0.0.
Everything committed, including history, issues and Actions logs, is public.
Never commit or print:

- secrets: access sessions and grants, signing material, provider
  credentials, App Store Connect keys, the ignored `Local.xcconfig`;
- user data: transcripts, recordings, dictionary contents, diagnostics logs,
  real screenshots, CloudKit exports or backup receipts;
- personal details and private infrastructure: people's names, private
  hostnames, tailnet or device names, device identifiers and home-directory
  paths.

`THIRD_PARTY_NOTICES.md` and `LICENSES/` are bundled into both apps and shown
under Settings > Third-party Notices; CI checks the bundled copies byte for
byte. A new or updated dependency updates both with its exact upstream text.

Fixtures, screenshots and evaluation audio are synthetic. Raw provider
evaluation results stay in the ignored `Evaluations/RealtimeTranscription/results/`.
Write `the maintainer` where a step needs the owner. Machine-specific values
belong in ignored local files, not in committed defaults.

## Ownership

| Path | Owns |
| --- | --- |
| `services/access/` | Mumla identity, sessions, sample allowance and bounded transcription adapter; its own AGENTS and README define the private operator contract |
| `Mumla/` | macOS menu bar app; `FlowCoordinator` routes dictation, paste and permission UX; `Onboarding.swift` is the first-run wizard |
| `ios/MumlaiOS/` | iOS containing app; `DictationCoordinator` owns sessions, dictation and audio notifications; `UI/OnboardingView.swift` and `UI/OnboardingStyle.swift` own the iOS wizard and its visual rules |
| `ios/MumlaKeyboard/` | iOS keyboard extension |
| `ios/Shared/` | Code shared only by the iOS app and keyboard: `DictationBridge.swift` (App Group IPC), `DarwinNotifications.swift`, `CrashReporting.swift` |
| `ios/MumlaiOS/Sources/Services/SessionAudioEngine.swift`, `AudioRouteValidationPolicy.swift` | iOS audio session and microphone routing |
| `Shared/Core/` | Code shared by both apps: `DictationLanguages.swift` (ordered ISO 639-1 list, system languages by default), `CloudPreferenceStore.swift` (iCloud KVS), `MumlaDataStore.swift` (SwiftData models and outboxes), `AudioArchive.swift`, `OriginalAudio.swift`, `AppCloudSync.swift`, `UnifiedDictationLibrary.swift`, and the access client (`AccessClient.swift`, `MumlaAccess.swift`, `AccessTranscription.swift`) |
| `Mumla.xcodeproj/project.xcproj` | The JSON Xcode project: targets, deployment versions, signing and entitlement wiring; edit it as JSON or in Xcode 27 |
| `Apple/Config/` | Shared build settings (`Mumla.xcconfig`), per-target Info.plists and the per-channel entitlement maps `entitlements-{ios,macos,developer-id}.json` |
| `Mumla/*.entitlements`, `ios/*/*.entitlements` | Entitlement values; every containing-app build uses the same CloudKit container and KVS identifier, Debug pins CloudKit to Production, and the keyboard has no iCloud |
| `.local/GrantKit`, `scripts/prepare-packages`, `scripts/GrantKit.revision` | GrantKit, checked out by `just packages` at one revision; replace it with a symlink to your checkout for GrantKit work |
| `Evaluations/RealtimeTranscription/` | Live-provider transcription evaluation corpus and tooling; its fixture manifest is canonical |
| `scripts/sign-bundles`, `scripts/app-store-connect`, `.github/` | Release signing checks, App Store Connect automation, CI and release |
| `distribution/mumla-mbag/` | The download page source and metadata |
| `.agents/skills/mumla-local-install/` | Replacing the locally installed macOS dev app |
| `.xcode-version`, `scripts/select-xcode` | The Xcode that CI, the release and local `just` commands build with |

`SpeechKit` is an exact-version-pinned public Swift package. GrantKit 0.1.1 is
pinned by revision and fetched over public HTTPS, without a deploy key. It owns
the guided permission flows: on macOS Microphone, Input Monitoring,
Accessibility and Screen Recording (status, System Settings deep links, the
drag-to-authorize panel, grant polling); on iOS the same `SystemPermission`,
`PermissionGuide` and `PermissionMonitor` API for the microphone plus reusable
onboarding UI (`PermissionStep`, `StepScaffold`, `HeroSymbol`). App wizards own
step sequencing; GrantKit owns each permission's interaction. Keep GrantKit
views theme-neutral: host apps supply button style, tint and spacing.

If this file and the code disagree, inspect the implementation and fix the
stale documentation in the same change.

## Invariants

### Identity and naming

- The product is Mumla. Keep the existing bundle, App Group, CloudKit, KVS,
  Keychain and persisted source identifiers, and the `WisprClone` directories
  under Application Support, Caches and Logs, so installed data stays readable.
- Do not change signing, bundle IDs, App Group IDs or release secrets without
  verifying the App Store Connect and provisioning-profile consequences.
- Minimum OS versions are iOS 26.0 and macOS 26.0; add no lower compatibility
  paths.

### Onboarding

[Onboarding](docs/design/onboarding.md) records both wizards' flows.

- Both wizards derive phases from persistent state, since macOS relaunches
  after an Input Monitoring grant and iOS kills the app when a permission
  flips in Settings, and end when a dictated transcript newly lands in their
  own field (`TryItLanding`).
- macOS: Restart is offered only if Input Monitoring was granted after
  launch, so the wizard never loops.
- iOS: `MumlaiOSApp` blocks on the wizard until
  `DictationCoordinator.setupComplete` (microphone, keyboard used once with
  Full Access) and, once started, until the try-it lands or is skipped. A
  missing keyboard stamp is an unconfirmed connection, never proof that Full
  Access is off. `mumla://debug/onboarding` (Debug) resets both.
- Use `OnboardingStyle.swift`'s primary-action modifier, spacing values,
  `OnboardingPrimaryButton`, `OnboardingSecondaryButton`, `StepScaffold` and
  `HeroSymbol` instead of per-step styling. Prefer semantic styles (`.tint`,
  `.primary`, `.secondary`); add a shared rule only for a real repeated
  pattern.

### Providers and credentials

- Both apps transcribe only with Azure MAI-Transcribe-2
  (`TranscriptionProviderType.dictation`) through SpeechKit's production
  implementation. The shared profile's model and cleanup fields stay readable
  for other apps, but Mumla's plans pin the model and disable cleanup. Older
  model IDs remain data in history and results. Mumla shows no model, provider
  or key anywhere; no provider key exists in the apps, recipes or configuration.
- The apps reach the model only through the access service
  ([design](docs/design/mumla-access-service.md)). `AccessClient` owns the
  device's session: one per verified CloudKit account, enrolled with a fresh
  `CKFetchWebAuthTokenOperation` proof per attempt, renewed within a week of
  expiry and ended on `.CKAccountChanged`. `MumlaAccess` publishes the
  allowance and issues one-use grants. `MumlaAccessOrigin` in the Info.plists
  sets the origin; the CloudKit API token comes from `MUMLA_CLOUDKIT_API_TOKEN`
  in the ignored `Local.xcconfig`.
- Progressive capture requests its grant while capture starts, never sends
  audio past `audio_limit_samples` and stops normally at that bound. Batch
  recovery reserves the recording's rounded duration. Only a transcription 401
  or 503, refused before dispatch, resends with a new grant; never resend an
  attempt that may have reached the provider. Grant and allowance requests
  retry 503 after jittered 0.5, 1 and 2 s.
- The keyboard reads `KeyboardAccessState` from the App Group and holds no
  credential. Keep provider-specific code small and route transcription
  behavior through SpeechKit.

### Data sync

`MumlaDataStore` keeps history, audio metadata and the structured dictionary in
one SwiftData store; `AudioRecordingPersistence` owns audio file I/O with its
own context off the main actor; `AppCloudSyncCoordinator` syncs through
`CKSyncEngine` in the private database's `TranscriptionHistory` zone of
container `iCloud.emileberhard.WisprClone`.

- Every distribution channel, Debug included, uses the Production CloudKit
  environment and reads and writes the real user's data. Tests pass
  `cloudSyncEnabled: false`; never run destructive sync tests in an ordinary
  development run.
- A model change and its `HistorySyncChange` or `VocabularySyncChange` outbox
  row are one SwiftData transaction. The sync actor owns a separate
  `ModelContext`; never pass SwiftData models or contexts across its boundary.
  Writes go through `MumlaDataStore`; SwiftUI reads with `@Query` against the
  scene-injected `ModelContainer`.
- Both platforms archive original audio before transcription, including
  failed, short and canceled captures. Capture encodes a 48 kHz mono Opus
  original in CAF (`OriginalAudioWriter`, ~96 kbps) beside the provider PCM16
  stream; providers receive PCM16 WAV, and Transcribe Again and realtime
  recovery derive it from the original. Write originals through `ExtAudioFile`
  with a zero packet-table reserve: `AVAudioFile` pads every CAF by ~236 KB, and
  Core Audio cannot write Ogg Opus. Metadata without `fileType` is a legacy
  16 kHz WAV, except that older clients drop the field from received Opus
  originals and name them `.wav`; startup relabels those once by their CAF
  header. Never expire recordings or delete their CloudKit records.
- `Application Support/WisprClone/AudioArchive` holds immutable JSON sidecars,
  chunk parts and audio not yet fully acknowledged; acknowledged and downloaded
  audio lives in the purgeable `Caches/WisprClone/AudioArchive`, and Listen,
  Export and Transcribe Again re-download purged audio from its chunk records.
  Startup reindexes sidecars after interrupted commits (a sidecar without
  durable audio is already in CloudKit) and offloads uploaded audio left in
  Application Support.
- `HistoryEntry.audioRecordingID` optionally links to an immutable recording,
  which several transcript versions may share. Deleting or clearing text history
  retains audio. Text-only legacy entries stay valid.
- `DictationAudioChunk` records carry encrypted metadata and `CKAsset` fields.
  Lossless 8 MiB chunks bound transfers, not recording length or retention; at
  most four chunks go in one send batch. Copy downloaded staging files before
  advancing the polling token, publish audio only after all chunks and its full
  SHA-256 verify, and keep the durable chunk outbox until acknowledgement.
- The macOS recovery adapter imports the old five-recording JSON store once with
  stable IDs and keeps those files for rollback. Audio sync errors show in the
  archive; failed uploads retain local originals and their pending work.
- The audio and vocabulary zone-replay markers force one full polling replay for
  older clients whose tokens may have passed record types they did not
  understand. Keep them, the seed markers, durable outboxes, sync-state files
  and the legacy JSON rollback backup.
- History uses deterministic UUID record IDs. Dictionary terms use normalized
  deterministic IDs, encrypted values, durable tombstones and last-writer-wins
  with the remote record winning ties. Never physically delete tombstones or
  change normalization without a migration design.
- The structured dictionary is canonical. Legacy newline/KVS values import as a
  union; new dictionary writes never go to KVS. Provider adapters filter
  incompatible hints; never truncate or reject stored terms for one provider's
  limits.
- Ordinary settings use KVS with the explicit identifier
  `$(TeamIdentifierPrefix)emileberhard.WisprClone.ios`, because Debug and
  Release bundle IDs differ.
- The Production CloudKit schema is additive-only: add fields or record types,
  never rename or remove deployed schema. After an additive change, use
  `Shared/Core/AppCloudKitSchemaBootstrap.swift`: temporarily pin the macOS
  Debug entitlement to `Development`, run `just bootstrap-cloudkit-schema`
  (it installs without a normal launch, so real data cannot sync into
  Development), deploy only the reviewed additive diff in CloudKit Console,
  verify both environments' exports match, restore the `Production` pin and run
  `just install-mac`. Never leave a Development-pinned app installed.
- Never reset a CloudKit environment, bulk-delete records or run test cleanup
  against Production without the maintainer's explicit approval. Local history
  wipes do not delete CloudKit data and re-sync on the next signed launch.
- Builds without the iCloud entitlement (unsigned `just build-mac`) and users
  signed out of iCloud keep the same local store without sync.

### Unified dictation library

[Unified dictation](docs/design/unified-dictation.md) and
[agent library access](docs/design/library-agent-tools.md) record the design.

- `UnifiedDictationLibrary` owns the optional SpeechKit `DictationLibrary`
  store, shared profile, capture plans, result versions and archive reader.
  Capture IDs are allocated before microphone input; shared captures have one
  canonical cloud writer. SwiftData rows with `unified/` sources are local read
  models. Profile writes go through its `DictationProfileWriter`: one at a
  time, each changing only its own field of the latest profile.
- `SharedHistoryProjection` materializes shared result IDs and original
  metadata into the account's SwiftData read models with no cloud outboxes and
  no audio downloads. `HistoryEntry.isHidden` keeps this device's Delete or
  Clear intent while the central archive and originals stay intact.
- The verified CloudKit identity selects the whole `Accounts/<SHA256>`
  partition of SwiftData, audio, outboxes and sync tokens. Account transitions
  invalidate its lease and replace the scene container. Unconfirmed and older
  root data stay separate; `LegacyDataOwnership` records explicit reconciliation
  before copying.
- `ProjectedZoneReceiver` persists old-zone metadata before advancing its token.
  CKSyncEngine schedules work but fetches no zones itself and never eagerly
  downloads audio assets. `ProjectedCloudTransportProbe` verifies this only in a
  Development-signed, isolated synthetic run.
- The opt-in macOS archival role keeps old and shared originals outside
  purgeable caches. `CombinedArchiveExporter` verifies and seals both under
  `CombinedDictationExports/<account-hash>/<timestamp-UUID>`; its 64 GiB budget
  stops catch-up when exhausted and never silently prunes originals. Derived
  export snapshots keep the latest two. `scripts/dictation-library-backup`
  copies sealed exports into independent recovery points
  ([contract](docs/design/dictation-library-backup.md)).
- The `mumla` CLI (installed by `just install-mac`) reads history and exports
  originals through the running app, on the Mac or a trusted connected
  iPhone (`--device <UDID>`). Private bounded request files authorize commands;
  `mumla://agent/<UUID>` only wakes the exact app. Library ownership and sync
  controls never belong in History or the composer.
- The signed macOS binary answers `--dictation-library list|search|audio`
  before normal app initialization, as JSON with account, freshness and errors.
  `MUMLA_LIBRARY_PROBE=1` exercises the real library with synthetic data and
  refuses any non-Development signature.
- Intentional CloudKit deletion pauses sync until explicit restoration.
  Encryption-reset recovery keeps a per-account restoration marker until
  metadata, results, profile and available originals are re-seeded; missing
  originals stay an actionable incomplete recovery.

### macOS app

- Debug is the local dev app: bundle ID `emileberhard.WisprClone`, named
  "Mumla Dev", unsandboxed, Apple Development signing, which keeps TCC grants,
  UserDefaults and the Keychain access session across installs. Release
  (`emileberhard.WisprClone.ios`, "Mumla") is sandboxed, so it cannot create
  Input Monitoring event taps or post synthetic Command-V and Return; no
  channel ships it, and the Mac ships only as the Developer ID download.
- The Developer ID build (`scripts/build-developer-id-dmg.sh`) is an
  unsandboxed hardened-runtime Release build with bundle ID
  `emileberhard.WisprClone`, archived unsigned and exported with the CI-only
  Developer ID certificate from the `testflight` environment, whose leak
  response is in [Canonical build](docs/design/canonical-build.md). Its DMG
  is signed, notarized and stapled as the outermost container.
- The download URL is `https://mumla.esmadil.se/`. `distribution/mumla-mbag/`
  holds the page, published with `just publish-page`; it links to the newest
  GitHub release's `Mumla.dmg` and reads its version, size and digest from the
  GitHub API. Never upload a DMG by hand. Keep the iOS card in its
  non-clickable "Coming soon on TestFlight"
  state until App Store Connect confirms the external build is available and
  the public link accepts testers.
- The access session lives in the data-protection Keychain (`KeychainStore`,
  DP-only queries). macOS grants keychain access groups only from a
  provisioning profile (TN3137), so Debug and Developer ID builds sign with the
  "Mumla Mac Development" and "Mumla Mac Developer ID" profiles, which share
  bundle ID `emileberhard.WisprClone` and one access group. Both apps delete
  retired provider-key items at launch. The `security` CLI cannot see these
  items; `--delete-credentials` removes them.
- For repeatable fresh-user testing: `just kill-mac` quits every instance,
  `just reset-permissions-mac` resets TCC (while an app is still installed,
  or tccutil silently does nothing), `just fresh-user-mac` wipes in order
  (kill, TCC, defaults with backup, access session, history with backup, installs;
  DMGs stay) and `just clean-dmgs` removes built DMGs. The wipe does not touch
  iCloud.

### iOS keyboard

- The keyboard extension never accesses the microphone; capture and
  transcription stay in the containing app. The keyboard shows dictation
  controls and special characters only; users switch keyboards for letters.
- `ABC` uses `advanceToNextInputMode()`; iOS cannot select a particular
  keyboard. Do not duplicate or customize the system Globe and Dictation
  controls at the bottom edge.
- IPC uses App Group `group.emileberhard.wisprclone` records for commands;
  Darwin notifications only wake the app.
- The keyboard inserts with `textDocumentProxy`, without key clicks or haptics
  for transcript delivery. iOS keeps replaced controllers' views and bridges
  alive, sometimes without `viewWillDisappear`, so "active" never means "on
  screen". Only the App Group transcript owner inserts: the bridge claims
  ownership on `viewDidAppear` and on the user's start/stop tap, and marks a
  transcript inserted only after a live, visible controller accepts it.
  Deactivated clients never refresh or consume transcripts.
  `MumlaKeyboardTests` (`just test-keyboard`) covers delivery with isolated
  defaults.
- Delivery is observable afterwards: lifecycle, ownership and insertion
  breadcrumbs (category `keyboard_delivery`) reach Sentry Logs and the device
  log at notice level; the keyboard reports an owner that cannot insert, and
  the backgrounded app reports a transcript still uninserted after
  `DictationBridge.keyboardInsertionReportDelay`.
- Key haptics and clicks are press-down feedback owned by `KeyboardFeedback`.
  Key rows keep contiguous hit targets with inset visual keycaps.
- "Start Session" must keep working from the extension; verify the launch path
  before replacing its `Link`-based behavior.
- The automatic start haptic is a durable App Group handoff: persist it before
  opening the app, let the visible controller deliver it after revalidating
  state, and clear it only after submission; never bind it to the launching
  controller.

### iOS audio session

- Keep `allowHapticsAndSystemSoundsDuringRecording` on so the keyboard keeps
  haptics while the app is recording-ready in the background.
- Prefer the built-in microphone. Never enable Bluetooth HFP input or silently
  fall back to AirPods or another microphone; Bluetooth A2DP is fine for output.
- Never use `defaultToSpeaker`: it can force media to the phone speaker with
  headphones connected, and the built-in mic then captures that media.
- The session is a mixable `playAndRecord` session from the moment the app
  starts it, with `mixWithOthers` and `allowBluetoothA2DP`, never
  `interruptSpokenAudioAndMixWithOthers` or `duckOthers`. The keyboard's tap
  only toggles whether the running engine's tap buffers samples; it never
  starts input or changes categories, which iOS can reject with
  `cannotInterruptOthers` (`!int`, `560557684`). The one exception is a session
  that already lost its input (engine stopped, an interruption without
  `.ended`, or the built-in mic missing from the route): dictation start
  restarts the engine once and ends the session if that fails.
- `currentRoute.inputs` can be briefly empty while the built-in mic is still
  available, as right after `setPreferredInput`. Defer and retry validation
  while the route has no inputs, but fail closed if the built-in route cannot
  be restored.
- `SessionAudioEngine` creates a fresh `AVAudioEngine` on every start and drops
  it after a media-services reset; a recording in flight is finalized with the
  PCM captured so far. An idle session whose restart fails after an
  interruption, a media-services reset or a failed idle restore retries on the
  `DictationInterruptionPolicy` probe schedule before ending.
- Dictation survives Siri-class announcements: on `.began` it pauses in place
  and force-resumes on the probe schedule, never gated on `.ended` or
  `.shouldResume`. No supported API prevents these interruptions (CallKit and
  capture-session tricks were rejected in July 2026).

### Swift and concurrency

- Targets use strict concurrency and default MainActor isolation. Keep UI and
  observable state on the main actor unless a real shared-mutable-state boundary
  requires otherwise.
- Closures passed to ObjC/C APIs that call back off-main, such as
  `AVAudioNode.installTap`, must be explicitly safe for that context and never
  silently inherit MainActor isolation.
- Prefer Swift concurrency tasks over timers for async loops.
- Never block the main thread on audio hardware. `AVAudioSession` and
  `AVAudioEngine` calls belong to the `SessionAudioEngine` actor, whose executor
  is its own serial dispatch queue; diagnostics read its published snapshot.
- `DictationCoordinator` handles session, dictation and audio-notification work
  as commands in one serial mailbox, each processed to completion, so actor
  reentrancy cannot interleave lifecycle transitions. Entry points and
  observers only enqueue; delayed probes carry an ID and are ignored once
  superseded.
- Never wait on semaphores or other synchronous handoffs from the main actor.
  macOS capture start awaits the session queue and first buffer; keyboard
  haptics use the async `CHHapticEngine.start()` and revalidate ownership
  afterwards.

### Diagnostics

- Diagnostics carry no persistent user or installation identity. `DiagnosticPrivacy` owns Sentry's privacy options, the only `beforeSend` and `beforeSendLog`; every Sentry setup calls it, automatic sessions stay off, and its tests must keep passing against the real SDK.
- Sentry project `mumla`. iOS events use `ios-release` and `ios-debug`
  environments and a `process` tag of `app` or `keyboard`. Every iOS
  `CrashReporting` breadcrumb and capture is also a Sentry structured log
  (attribute `category`; `sentry.release` separates app and keyboard). Logs
  buffer up to 5 s, so a killed keyboard can lose its last entries.
- Keep the keyboard's Sentry setup lean: crashes and explicit errors, no app-hang
  tracking.
- Diagnostic messages are `StaticString`. Errors reach every sink (Sentry
  events, logs and breadcrumbs, the system log, the Mac log file) only through
  `DiagnosticError` in `Shared/Diagnostics/`: reflected type, numeric code, the
  Cocoa, URL, POSIX or OSStatus domain or else the type, and for `SpeechKitError`
  its case and HTTP or WebSocket status (`Shared/Core/SpeechKitDiagnostics.swift`,
  containing apps only; the keyboard links no SpeechKit). Never render an error's
  description, user info or provider text into a message or metadata.
- Metadata holds state, fixed reason strings, IDs, counts and timing, never
  user-facing messages or transcript, dictionary or screen content. Sentry's
  network breadcrumbs record full HTTP query strings, so keep user content out
  of request URLs; it does not track WebSocket tasks.
- When the apps change what they store or send, update `PRIVACY.md` in the
  same change and tell the maintainer, because the App Store privacy label must
  match.
- The iOS app's and keyboard's `PrivacyInfo.xcprivacy` declare each
  required-reason API and collected data type; declare new uses in the same
  change.
  Active-keyboard state never leaves the device.

## Build and validation

| Command | Use |
| --- | --- |
| `just packages` | Check out GrantKit at its pinned revision; other recipes run it first |
| `just build-mac` | Compile the macOS app, signing disabled |
| `just build-sim` | Compile `MumlaiOS` and the keyboard for the simulator |
| `just test-keyboard` | Keyboard delivery tests on macOS |
| `just test-access-live` | Live access acceptance from the signed Debug Mac app: CloudKit enrollment, proof replay, Transcribe Again, paced uploads to the 110 s bound |
| `just realtime-eval` | Resume the provider evaluation from completed atomic run logs with adaptive concurrency |
| `just install-mac` | Build signed Debug, replace `/Applications/Mumla Dev.app`, install the `mumla` CLI and launch; stamped with the latest version tag |
| `just build-iphone`, `just install-iphone`, `just deliver-iphone <app>` | Signed development checkpoint for a physical iPhone and its delivery; development builds use marketing version `0.0.0` |
| `just keyboard-preview-*`, `just keyboard-layout-preview-*` | Simulator keyboard checks in the real extension host; see [keyboard previews](docs/keyboard-previews.md) |

`just` alone lists every recipe. Signed recipes use the maintainer's signing
and device tooling; contributors use the unsigned recipes or their own team.
The ignored `Apple/Config/Local.xcconfig`, included last by `Mumla.xcconfig`,
overrides project-level settings such as `DEVELOPMENT_TEAM` and supplies
`MUMLA_CLOUDKIT_API_TOKEN`; bundle identifiers and the Debug targets' manual
signing profiles are target settings that outrank it. Builds resolve only the
committed `Package.resolved`; `.xcode-version` names the Xcode, and
`DEVELOPER_DIR` overrides it per invocation. Update that one file when moving
Xcode and check that the hosted image has it.

Use the smallest relevant validation. Keyboard UI changes are checked on a
physical iPhone unless asked otherwise. If a build cannot run, state the
blocker and run the next best static check, such as `git diff --check`.

### Live integration gate

New functionality needs meaningful Swift Testing tests at the production
boundary. For any new or changed external API behavior, including providers,
models, authentication, request options, upload formats and finalization, or a
dependency change that alters it, add or update a live integration test and run
it successfully before merging or releasing.

- Exercise the app's actual factory, session or engine, audio handoff and
  result handling through SpeechKit's production implementation; never
  duplicate HTTP requests in the test or substitute a minimal SDK probe.
- Use the installed app's credential resolver, endpoint, model and options,
  with realistic language and dictionary settings and a boundary case for any
  documented or observed provider limit.
- Run the access path from the signed Debug Mac app (`just test-access-live`),
  since unsigned test bundles hold no CloudKit identity. Keep microphone permissions, keyboard IPC, background audio and
  physical-device acceptance separate, and add no UI automation to test a
  network adapter.
- Use short synthetic fixtures, bounded timeouts, and assertions on meaningful
  output plus terminal completion. Unit tests cover deterministic limits,
  failure and cancellation alongside the live test.
- Live tests may be opt-in during offline development, but during this gate
  they must execute: missing credentials, a skipped test or an unreachable
  provider blocks the claim. Report the exact command, result and remaining
  boundary.

## Release

A pushed annotated `MAJOR.MINOR.PATCH` tag on `main`, higher than every other
version tag, releases everything, and that tag is the version of every artifact:
the access service, iOS TestFlight and the App Store, the Developer ID DMG and
the GitHub release. The tag message lists user-visible changes, one short
sentence per line, and becomes What to Test, What's New and the release notes.
Choose the bump from the changes since the latest tag: patch fixes, minor adds,
major removes or changes what installs rely on.

```bash
git tag -a x.y.z -F notes.txt
git push origin x.y.z
```

`.github/workflows/release.yml` runs on hosted runners only and follows
[Canonical build](docs/design/canonical-build.md). It admits the tag after
`ci.yml` passes on the same commit and reserves build numbers. The iOS lane
writes the `testflight` environment's `MUMLA_CLOUDKIT_API_TOKEN` into
`Local.xcconfig`, signs each bundle ad hoc with
`Apple/Config/entitlements-ios.json`, exports with Xcode cloud signing and
checks signing (`scripts/sign-bundles check`) and access configuration
(`scripts/check-access-configuration`). Its upload, the `Public Beta`
TestFlight review and the iOS App Store version, prepared short of App Review,
wait up to 30 minutes for the access service to report the tag's version and
commit. In parallel the `developer-id` job builds the notarized DMG on the
same environment; the GitHub release publishes it as `Mumla.dmg` once both
channels finish, so it also follows the service gate.

- App Review submission and the App Store release stay with the maintainer.
- Every channel carries the tag's version; Developer ID and TestFlight build
  numbers may differ. A published version is immutable: its DMG is never
  replaced, and the download never rolls back to an older version.
- Retry with "Re-run failed jobs" in the tag's own run while that tag is the
  newest. Retries reuse the uploaded builds and the published DMG, whose
  digest a retry must match. Re-running all jobs builds a different DMG that
  the published one rejects; a mismatch or a fix ships as the next patch.
- The `testflight` environment (App Store Connect, Developer ID, Sentry,
  CloudKit token) is limited to version tags, so `main` and version tags stay
  maintainer-only.
- Cloud signing needs the App Group on every App ID; capability edits
  invalidate profiles, including the `testflight` Developer ID profile secret.
- iOS and the sandboxed Mac target share `emileberhard.WisprClone.ios` (one App
  Store Connect record), plus `.keyboard` for the keyboard; Developer ID uses
  `emileberhard.WisprClone`. Team `NNP2B278S6`, App Store Connect
  app `6779234657`. External testers join through
  `https://testflight.apple.com/join/sV7brtJM`; query the live group, build and
  review state before linking it from the download page.

## Ask first

Ask the maintainer before destructive git operations, deleting user data,
changing signing identities, or sending externally visible communication not
explicitly requested. Check Apple's current documentation, or crash
diagnostics, rather than guessing when behavior depends on keyboard extension
policy, audio sessions, haptics, App Groups or CloudKit.

## Documentation

Keep this file short and operational, within Codex's 32 KiB default, and move
long reference material to `docs/`. Update it, the README, `PRIVACY.md` and
`docs/` in the same change as the behavior, commands, release flow or paths
they describe.
