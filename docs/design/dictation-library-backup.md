# Dictation library backup

`scripts/dictation-library-backup` copies the sealed exports of a Mac's archival role into independent, verified recovery points at a destination you choose, such as a second disk. A destination on the same host is second-disk recovery, not off-host disaster recovery. The export is the working copy; the backup is separate bytes.

## Contract

```
dictation-library-backup backup  --dest D [--export EXPORT_DIR | --exports-root R] [--budget-bytes N] [--keep-daily 14]
dictation-library-backup verify  --dest D [--budget-bytes N]
dictation-library-backup status  --dest D [--budget-bytes N]
dictation-library-backup restore --dest D --account A [--snapshot ID] --target NEW_OR_EMPTY_DIR
```

Every command requires an explicit destination, for example `--dest /Volumes/Backup/mumla-dictation`. Defaults: `R=~/Library/Application Support/WisprClone/CombinedDictationExports`, budget 96 GiB. Without `--export`, the newest sealed export of every account under `R` is backed up. Python 3.14 stdlib only (PEP 723, `uv run --script`).

stdout is exactly one JSON object (`ok`, `command`, `format`, plus `destination.used_bytes/budget_bytes`); stderr is unused. Failures carry `error.kind` and exit codes:

| code | kind | meaning |
|---|---|---|
| 0 | | success |
| 1 | io | unexpected I/O error |
| 2 | usage | bad arguments |
| 3 | capacity | 96 GiB cap or volume space cannot be met; nothing published, latest preserved (also `verify`/`status` when usage exceeds the cap) |
| 4 | source | export unsealed, symlink/special file, traversal, manifest mismatch, or mutation while copying |
| 5 | integrity | destination blob or index failed verification |
| 6 | destination | not empty and not owned, bad marker, or unsupported format version |
| 7 | busy | another process holds the destination lock |
| 8 | target | restore target not new/empty, inside the destination, or recovery point missing |
| 9 | incomplete | source manifest says `complete: false`; the last-good recovery point is untouched |

`backup` results are per account. The first failing result decides the exit code, and the other accounts are still attempted. Each result has `status` (`created` or `unchanged`), `snapshot`, `created_at`, `verified_at`, `files`, `bytes`, `new_blob_bytes`, `repaired_blobs`, `pruned_snapshots`, `is_latest`, `source_manifest_sha256` and `source`. `source` is the sealed manifest's own `complete`, `createdAt`, `freshness` and `completeness`, passed through (lists as counts) and never computed here. `status` returns the same receipt per account as `latest`, which is also persisted at `accounts/<account>/latest.json`.

## Source assumptions

A sealed export is `<root>/<accountHash>/<exportId>/` as written by SpeechKit `DictationArchive.export(to:)` (`DictationLibrary/Sources/DictationArchive.swift`): `manifest.json` written last, then the staging directory renamed into place; `.staging-*` directories are unsealed and ignored. The manifest must have `formatVersion: 1`, `account: {hash}` equal to the parent directory name, `complete: Bool`, `createdAt` (seconds since 1970), `freshness` and `completeness` objects, and `files[{path, byteCount, sha256}]` for every file except `manifest.json`. A backup requires that file list to match the tree exactly (path, size, SHA-256), so a half-written or altered export is rejected and never published. Anything else (the legacy exporter's `version`/`account`-string manifest included) fails with `source` instead of being guessed at.

`freshness` and `completeness` are not interpreted: scalar values are passed through into `source` and lists are replaced by their length (so `missingAudioCaptureIDs` and `problems` appear as counts and no ids or record names reach receipts). A manifest key that is absent in the export (`lastCatchUpAt` before the first catch-up) is absent in the receipt. Empty directories are not recorded and not restored.

Export ids compare lexicographically as chronological (UTC second timestamp, nine-digit fraction, then UUID). `--exports-root` picks the newest sealed export per account, and the latest pointer only moves to an id that sorts at or after the current one. Only that newest export is attempted: if it is incomplete the run reports `incomplete` (exit 9) and does not fall back to an older complete one, which an earlier run already backed up.

A composed export that also carries the legacy Mumla archive must keep this manifest shape and list every nested file (for example under `legacy/`) in `files`, with `complete` covering both parts. The two exporters must not share an account directory, because SpeechKit retention deletes every non-hidden sibling beyond the newest two.

## Destination layout

```
.mumla-dictation-backup.json   marker: {format, kind, id}; written only into an empty directory
lock                                flock; one process at a time
blobs/<sha[:2]>/<sha256>            read-only, content-addressed, shared across snapshots and accounts
accounts/<account>/snapshots/<exportId>/snapshot.json   {format, account, snapshot, created_at, files[{path,size,sha256}]}
accounts/<account>/latest.json      verified receipt
staging/                            in-flight work, emptied at the start of every run
```

Anything outside this namespace is never read, counted or deleted. A non-empty directory without the marker fails with exit 6 and is not touched (not even a lock file).

## Guarantees and mechanics

- **Fourteen points without fourteen copies.** Original files are stored once by SHA-256; a snapshot is only an index. Identical audio across exports and recovery points costs nothing extra.
- **No inconsistent publish.** Pass 1 hashes the source with before/after stat checks; pass 2 copies only blobs the destination lacks while re-hashing, so a file that changed fails the run. The tree is rescanned before publication. Blobs are fsynced, then every blob of the snapshot is re-read from the destination with `F_NOCACHE` and compared. Only then is `snapshot.json` renamed into place, followed by `latest.json`. A crash leaves an orphan stage or blobs, cleaned by the next run.
- **Idempotent.** Re-running a sealed export re-verifies it and refreshes `verified_at`. The same id with different content fails with `source`. A damaged destination blob that the source can replace is repaired and reported in `repaired_blobs`; the repair is read back too.
- **Latest per account.** `latest` moves forward only (never to an older export id). Retention keeps the newest recovery point of each of the 14 most recent Europe/Stockholm days per account, plus latest, and deletes only snapshots in this namespace. Blobs unreferenced by any snapshot are then collected.
- **Cap.** The 96 GiB cap counts allocated bytes of everything owned (marker, lock, blobs, indexes, staging). Before copying, the run computes the new allocation; if the cap would be exceeded it first prunes recovery points that retention would delete anyway (the current latest is pinned), then fails with `capacity` without publishing. A cap that cannot be met is a visible nonzero exit, never silent deletion of the latest point. Source exports and originals are never touched.
- **Streaming.** Files are processed in 4 MiB chunks; memory is bounded by the file list, not archive size.
- **Paths.** Source symlinks, special files, `..` and empty components, over-deep paths and case-insensitive collisions are rejected at backup. Indexes are re-validated at verify and restore, and restore uses `O_EXCL|O_NOFOLLOW` into a new or empty directory outside the destination, removes what it created on failure, and never overwrites.
- **Diagnostics** contain counts, byte totals, checksums and the opaque account hash and export id, never file names.

## Operating notes

The caller, typically a scheduler, runs `backup` after a successful export and treats a nonzero exit as an alert; `status` is the cheap read for UI display. Recovery point retention is a policy of this script, so a different count is changed with `--keep-daily`, not by editing the destination. A destination on the same host does not survive the loss of that host, and the interval between the export and the next successful backup is the uncovered gap that `latest.verified_at` exposes.
