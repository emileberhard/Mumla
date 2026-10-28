# Agent library access and legacy reconciliation

The existing account partition remains the only writable library. Agent requests run through the already-running app and its account lease, rather than opening another CloudKit coordinator over the same files. A thin `mumla` CLI sends bounded private request files and uses a URL containing only their random identifier to wake the exact app. The URL alone grants no operation. The same contract works over CoreDevice on an iPhone. Responses are atomic JSON, account hashes replace raw account identities, and requests expire. Normal History views contain no ownership workflow.

Reconciliation compares the retained legacy stores with the verified account replica after metadata catch-up. Stable IDs identify duplicates; an exact text, date and audio match also identifies a duplicate created under another ID. Conflicting text or audio under an existing ID stops reconciliation. Unique history and newer dictionary changes enter the existing durable outboxes; unique audio uses the existing archive writer. Ownership is recorded before copying and completion afterward, which makes interrupted reconciliation restartable. Retained sources remain intact for rollback. The command requires the account hash returned by inspection and checks the lease across suspension.

The alternatives were a second standalone sync engine, direct SQLite mutation, and a daemon. They create competing writers, bypass persistence invariants, or add a service solely to wake an app. File requests plus platform URL delivery reuse the existing process owner. CoreDevice access requires a trusted connected device; there is no remote public API or new server. Read results describe the local replica and explicit catch-up, not a claim that every cloud asset is downloaded.

The CLI exposes status, bounded history list and search, original audio export, and legacy inspection and reconciliation. The signed `--dictation-library` archive reads remain available. It adds no policy configuration, automatic deletion or indexing service.

## CLI

`just install-mac` installs an immutable copy of `scripts/mumla` to `~/.local/bin/mumla`. Each command prints one JSON response; exit codes are 0 success, 1 app operation failed, 2 arguments, transport or integrity failure, and 3 pending. `result <request-id>` reads an existing receipt without repeating the operation. Inspect pending requests before retrying. Completed command folders expire after an hour; at most 32 retained requests, each with an 8 MiB response, are accepted.

```sh
mumla status
mumla export
mumla list --limit 20
mumla search 'an idea' --limit 20
mumla audio --id RECORDING_UUID --output /tmp/original.caf
mumla legacy inspect
mumla legacy reconcile --account ACCOUNT_HASH_FROM_INSPECTION
mumla --device EXACT_HARDWARE_UDID legacy inspect
mumla --device EXACT_HARDWARE_UDID legacy reconcile --account ACCOUNT_HASH_FROM_INSPECTION
```

The app must have a confirmed iCloud account. History reads catch up metadata and include legacy transcripts plus shared result versions, retaining their provider and model provenance. List and search never fetch archive audio. Original export verifies length and SHA-256 and refuses to overwrite an existing output. Reconciliation reports remaining outbox counts separately from successful local import. Source files are retained, not deleted. A failed account check, catch-up, malformed persistent store, content conflict or missing original is an error rather than an empty library.

## History integration

`SharedHistoryProjection` materializes shared immutable result IDs and original metadata into the same account-specific container that normal History and Recordings query. It uses its own actor and context, creates no cloud outbox rows, and never downloads audio. Existing derived local rows with the same capture and text are collapsed into the canonical result ID. Foreground and visible-history refreshes catch up the SDK catalog; unchanged entries skip database work. Listen and Export fetch originals on demand through the SDK owner. Account transitions replace the projector and invalidate its lease. This keeps the existing History UI instead of adding a separate archive browser.

Retained audio is validated against its pre-existing checksum before copying, and polling failures retain the dispatched request ID. Responses use the app container defaults plus private permissions and atomic replacement, because explicitly applying iOS-style file protection to a macOS response can prevent a CLI read while the Mac is locked.

Local History writes use the SDK result ID and original text, preserving delivery-only trailing spaces solely in the pasted text. Older derived rows are matched with trimmed text. Shared rows deleted or cleared from History keep a local `isHidden` marker; projection preserves that intent across restart and later result versions. This hides a result from this device's History and CLI history, while the immutable central archive and originals remain. Legacy CloudKit deletion behavior is unchanged.

Phone commands activate the exact Mumla app so UIKit delivers the URL; CoreDevice background-only launches can leave scene URL delivery pending while another app is in front. The Mac route remains a background open. A pending request is never treated as successful, and its ID remains available for readback.

Focused Swift tests cover the data store, projection concurrency, trailing-space deduplication, account invalidation, and Delete or Clear followed by restart and a later result; Python tests cover the CLI.
