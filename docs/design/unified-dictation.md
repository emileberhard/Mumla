# Unified dictation

SpeechKit owns the optional `DictationLibrary` product. Mumla edits the
shared personal profile and dictionary and browses recordings made by itself
and by other speech apps that use the same library, such as RemoteCoder and
AgenTTY. Each producer publishes directly; opening Mumla on the recording
device is not required for publication. Mumla continues finishing and publication
through the iOS app's available background time.

Each producer owns a private, account-bound capture store and durable outbox.
The capture ID and recoverable PCM journal exist before recording starts.
Originals are immutable, and provider output and cleanup are separate result
versions with their effective plan. Host insertion and delivery receipts never
authorize deleting an archival original. Shared settings remain effective when
original archiving is disabled. Terminal context disables prose cleanup.

The existing private CloudKit zone remains canonical. Producers read only their
profile and dictionary and publish captures; explicit archive readers fetch
projected metadata and retrieve audio on demand. The legacy sync engine keeps
send scheduling but delegates reads to the projected receiver. This avoids
duplicating every audio asset into every speech app. The alternatives were an
App Group inbox, which waits for Mumla on that same device, and full per-app
replicas, which cost storage, downloads and authority for nothing. Shared
CloudKit entitlements do not provide server-enforced per-app append-only
access; the narrow publisher API is an application boundary.

Account changes invalidate leases and isolate cached state and pending writes.
Unverified captures are held for explicit assignment; known other-account
captures cannot be adopted. Older local Mumla history has no proven owner, so
it stays separate until it is inspected and explicitly reconciled; it is never
assigned to the current account or included in that account's backup
implicitly.

Producer storage is capped at 512 MiB. Each publication pass releases the
oldest fully uploaded originals whose capture and chunks still exist in CloudKit
until the store is at most half full. Held, unacknowledged and missing-cloud
originals stay local. Free Uploaded Local Audio releases the rest on request.
The optional macOS archive role retains a full
replica and composes unified and confirmed legacy exports within a 64 GiB
budget. `CombinedArchiveExporter` seals them under
`CombinedDictationExports/<account-hash>/<timestamp-UUID>`. Derived export snapshots keep the latest two. Sealed manifests use Unix-epoch
seconds and checksummed file lists. The
[backup CLI](dictation-library-backup.md) retains verified recovery points
within its own 96 GiB budget. Cloud acknowledgment, a retained replica and an
independently verified backup are separate states. Intentional cloud deletion
pauses recovery for a decision; recognized encryption-key loss can reseed
retained data for the same account.

## Validation

- SpeechKit 0.1.1 was published at revision
  `4a7d06482656e925d2c2e7c17d8b281c2a2d2c69` before consumers upgraded.
- Production gained four additive record types and the vocabulary record-ID
  query index; no existing type, field or grant was removed.
- A signed Development integration exercises real publication, projected
  catch-up, restart, on-demand original verification, Mumla's archive reader,
  shared settings with archiving off, the unattended native search and audio
  commands, and a real library export through backup and byte-identical
  restore.
- The legacy transport proof delivered zero asset fields and bytes during
  initial, replay and restart metadata fetching while the real sync engine
  scheduled sends. This measures API-delivered assets, not network traffic
  below CloudKit's XPC API.
- Consumer release, installation, Production capture and readback, archival
  catch-up and a first backup are separate delivery gates.

## Preferences and latency

Connected apps display and edit the shared model preference. Mumla shows no
model or cleanup controls and always dictates with MAI-Transcribe-2 without
cleanup. Spoken Languages in Settings is the one place for languages, and it
edits exactly what dictation reads: `UnifiedDictationLibrary.dictationProfileSource`
is the one decision behind both `prepareCapture` and the section's owner.
Settings applies it to the library's cached profile state and capture to the
store's live state, so the two can disagree briefly during a refresh. A
ready shared profile owns languages (an empty list means Automatic). Without
one, the local list owns them until archival consent is known; after that,
dictation uses an unverified plan with Automatic and the section is read-only
with its reason. Profile saves show their progress and failures in place.
`DictationProfileWriter` runs one profile write at a time: each fetches the
latest profile when its turn comes, changes only its own field (languages or
recording storage), saves with the change tag and retries once on a conflict.
A write fails rather than build on a cached profile served after a failed
cloud read, and encryption-reset restoration runs on the same chain. An
account change drops pending edits and their retry. A write from another
device between that fetch and SpeechKit's internal save can still be
overwritten until SpeechKit offers a payload-only update. `MumlaDataStore` owns
the dictionary: capture plans take its terms at capture time, because the
shared profile's dictionary is the uploaded vocabulary and lags pending edits. Local microphone permissions, app shortcuts
and delivery behavior remain host-owned.

Archival status belongs in Settings, never in a composer. Original sealing runs
independently of text delivery and is drained by its library owner. Mumla ends
microphone buffering before overlapping original sealing and provider
finalization. PCM journals remain recoverable throughout sealing.

The implementation follows Apple's [Task lifetime contract](https://developer.apple.com/documentation/swift/task)
and [structured-concurrency guidance](https://developer.apple.com/videos/play/wwdc2023/10170/).
Only work that must outlive a lexical call uses a retained task; consequential
account leases are revalidated after suspension.

Shared-settings edits retain the account lease of the displayed controls. A
late profile refresh cannot undo a completed local preference write. Producer
publication retries after sealing, and workspace termination drains pending
original finalizations even when no gateway targets remain.

Normal History includes shared captures from other producers through
account-bound SwiftData read models, with audio fetched only on request. See
[agent library access](library-agent-tools.md) for the command contract.

## Publication lifetime and diagnostics

The library owns one coalesced producer task. Sealing enters its background
work owner before `finish()` starts and admits publication before releasing
that work. Result writes follow the same pattern, so overlapping operations
share one UIKit background assertion until idle. Expiration cancels the pass
and ends the assertion. Finishing a seal after expiration cannot start another
pass in that expired work interval; durable originals and receipts let later
admitted work resume.
The Mac implementation needs no UIKit assertion.

One helper calls `publishPending()` and records pending-before/after, held and
failure counts, duration and outcome through the host diagnostics. At most three
capture failures include only UUID, typed case, domain and numeric code via
`DiagnosticError`; no descriptions, account identifiers or dictation content
enter these records. Foreground refresh no longer runs recovery separately:
SpeechKit's pass owns recovery before account verification, newest-first
publication, chunk-before-capture-before-result ordering, retries and receipts.

The Development-only synthetic CloudKit probe observes publication from a
second reader and immediately verifies any visible capture's original. It
resets local receipts and proves replay acknowledges every record without
changing its server change tag. A different-hash capture conflict leaves only
that capture pending while a healthy capture publishes. These checks run inside
the probe's existing signature, absent-profile and temporary-directory isolation;
cleanup targets only its synthetic Development records. Signed `--dictation-library list|search|audio` commands run before normal app
initialization and return JSON with account, freshness and errors. They read
through a separate temporary archive reader and never open a producer spool.
`MUMLA_LIBRARY_PROBE=1` refuses a non-Development signature.
The keyboard has no producer or CloudKit store.

Apple references: [CloudKit request configuration](https://developer.apple.com/documentation/cloudkit/ckdatabase/configuredwith(configuration:group:body:)-637p1)
and [extending background execution](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time).
