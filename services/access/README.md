# Mumla access

A single Bun service verifies iCloud identity, issues device sessions and enforces
one shared monthly transcription allowance. The approved boundary is recorded in
[the access design](../../docs/design/mumla-access-service.md).

```sh
bun install --frozen-lockfile
bun run check
bun test --timeout 5000
bun build.ts 1.2.3 <full-source-commit> <output-file>
```

Use the exact Bun version in `.bun-version`; the build refuses another runtime.
The build produces one Linux x64 executable with its version and commit embedded.
The private tag poller builds only admitted annotated releases from main; CI uses
0.0.0 to check the build. A release uses the app's same plain version tag. The
public release must wait for this version's open, ready health before app uploads.

## CLI and private configuration

`mumla-access version` prints `{version,commit}` without loading configuration.
`mumla-access init --config <absolute-private-json>` explicitly creates the
initial ledger and refuses an existing path. The deploy poller never initializes
state. `mumla-access serve --config <absolute-private-json>` requires the
existing ledger and starts fenced on loopback. `mumla-access check --config
<absolute-private-json>` validates the configured **offline snapshot** read-only
and checks the live router's `/health` response and checks the configured
CloudKit API token with `users/caller` without a user proof (421
`AUTHENTICATION_REQUIRED`). Definite denial, 400/404, 401 authentication failure
or an unexpected 200 fails with exit 1. Transient CloudKit network, timeout and
server failures leave identity unproven: `check` prints
`{version,commit,ready:false,identity:"unproven"}` and exits 75 (retryable).
Only a proven API token prints `{version,commit,ready:true,identity:"proven"}`
and exits 0, so an outage cannot admit an unproven candidate. A running service
keeps existing sessions and transcription available during those transient
failures and gates enrollment only. Neither check dispatches provider work. The
offline check must not be pointed at the live exclusive database. Run both the candidate and
previous executable against the snapshot before fencing production.

Configuration is a required JSON object; no operator defaults are committed:

| Field                | Contract                                                      |
| -------------------- | ------------------------------------------------------------- |
| `listenPort`         | Unprivileged loopback port                                    |
| `database`           | Absolute private SQLite path; parent directory already exists |
| `cloudKitContainer`  | Existing containing-app container, Production                 |
| `cloudKitAPIToken`   | Container API token; also an app release input                |
| `routerOrigin`       | HTTP loopback origin with no path or credentials              |
| `routerKey`          | Server-only restricted transcription key                      |
| `operatorToken`      | At least 32 random characters; operator endpoints only        |
| `freeMonthlySeconds` | Initially 3600; service-owned policy                          |
| `subjectOverrides`   | Object from verified subject UUIDs to monthly seconds         |

The apps take the origin from `MumlaAccessOrigin` in their Info.plists and the
CloudKit API token from the release environment's `MUMLA_CLOUDKIT_API_TOKEN`.
Neither is an inference credential. No router key is included in any app.

Use one unprivileged systemd service, private state directory, `UMask=0077`,
`Restart=on-failure`, `TimeoutStopSec=10` and `SendSIGKILL=no`. Start command is
the `serve` command above. Configure an explicit `RestartSec` and start-limit
policy in the private unit; do not rely on systemd's rapid-restart defaults. The
private poller sends SIGTERM only after a successful idle fence; the process
refuses an active shutdown and reports an incident. Private ingress is the
Cloudflare tunnel: it provides TLS, supplies `CF-Connecting-IP`, rejects
`/internal/*` from public traffic and caps headers/bodies. The listener is
loopback only; Cloudflare overwrites the client IP header. No generic forwarding
headers are trusted. Enrollment requires that IP; missing/invalid IP refuses
only that request with 503 and an incident log limited to once per minute.
Acceptance must verify the real IP and a paced progressive upload that reaches
the apps' 110-second bound, including normal completion and cancellation, through
the real tunnel. Enrollment permits 10/origin/minute (IPv4-mapped IPv6 normalizes to
IPv4; other IPv6 allows 10 per /64 and 100 per /48) with no shared minute budget,
so junk from a few origins cannot lock out everyone's sign-in; a full 10,000-entry
origin table forgets its oldest entry. At 32 sessions, enrollment
evicts the earliest-expiring (least recently renewed) session and revokes its
unused grants. At most two attempts and four data requests per account run
concurrently; the per-account request cap is checked before the 64-request
global pool. Health and operator routes remain available outside that cap.
Enrollment has eight separate slots and never blocks the idle fence. Both
enrollment and grant bodies have two-second deadlines; grant requests
authenticate before body reads. Claimed uploads must provide the validated WAV
header and first complete PCM sample within three seconds. Dispatch starts when
Bun fetch pulls the rebuilt request body's first bytes, after validating the
44-byte WAV header. A claimed attempt the client fails, dispatched or not,
including a header-only stall or invalid upload, costs at least one second; a
fence or closed admission before dispatch returns retryable 503 for free.

## Operator HTTP contract

All operator calls use `Authorization: Bearer <operatorToken>` on loopback;
there are no caller-selected files, commands or credentials in request bodies.
Responses use `Cache-Control: no-store`.

| Request                 | Response                                                                                                   |
| ----------------------- | ---------------------------------------------------------------------------------------------------------- |
| `GET /healthz`          | Public; 200 `{version,commit,ready:true}` only when initialized, checked and admission open; otherwise 503 |
| `GET /internal/status`  | 200 `{version,commit,ready,admission_open,active}`; usable while fenced                                    |
| `POST /internal/backup` | 200 `{sha256,bytes}` after atomically publishing `${database}.backup`; 409 if another backup runs          |
| `POST /internal/fence`  | 200 `{admission_open:false,active:0}` if idle; 409 with current state/count otherwise, admission unchanged |
| `POST /internal/reopen` | 200 `{admission_open:true,active}` only when ready                                                         |

`active` is dispatched uploads plus a backup in flight. Enrollment is nondurable:
an idle replacement can interrupt it, and the client retries. Enrollment checks
admission again before committing, so it cannot persist after a fence. Closing
admission cancels pending enrollment bodies, CloudKit proof exchanges and
undispatched claimed uploads. Those uploads return 503 and release the grant
without charge; the client requests a new grant. Unused grants do not block
idle: the synchronous idle fence revokes them before closing admission. A client
automatically retries a retryable 503 grant refusal. A fence-revoked grant
returns 401 `invalid_grant`: request a new grant without
re-enrolling. Never retry an uncertain inference upload.

The router readiness probe requires its documented `/health` response with
`service: "llm-router"` and `status: "ok"`. It proves router health; the live
app integration gate separately proves the server key, transcription permission
and provider behavior. This readiness gap is accepted for launch: a wrong router
key fails closed through the fatal 401/403 incident on inference. CloudKit API
probes have a three-second deadline. `ACCESS_DENIED`, 400/404, 401
`AUTHENTICATION_FAILED` or an unexpected 200 fails startup. Transient probe
failures keep the process up but return `503 identity_unavailable` to
enrollment. Enrollment retries the probe on demand with a shared, jittered
exponential backoff from one second to about a minute; no user proof is sent
before it succeeds. Runtime 401 `AUTHENTICATION_FAILED` reports the
`cloudkit_configuration_invalid` incident; 403/`ACCESS_DENIED` reports
`cloudkit_access_denied`. Both refuse only that request with 503 and a bounded
incident log. A runtime 421 authentication error returns 401 `invalid_identity`.

The live owner makes a consistent `VACUUM INTO` snapshot with integrity validation
and SHA-256. The temporary snapshot is chmod 0640 before atomic publication in
the service-owned, backup-group-readable setgid directory (mode 2750). The live
ledger and private configuration remain private to their owners. The poller
copies the published snapshot plus private configuration, verifies the hash
and SQLite integrity, and retains the latest two recovery points. It never copies
a live WAL database or restores old usage during executable rollback. No identity
secret exists. The initial schema is version 1 and rollback-readable; future
schema changes need an explicit compatibility transition.

The private poller prepares/checks while open, waits at most 900 seconds for idle,
fences atomically, replaces, validates status, then reopens. Failure before fencing
leaves admission open; failure after fencing restores the compatible previous
executable and reopens. An ambiguous state is inspected before any shutdown.
No active capture/upload is killed to complete a normal deployment. If sustained
traffic measurably prevents idle deployments, a reviewed drain step or overlapping
slots will be needed; neither is launch scope.

The private poller is the single admission owner after restart as well as during
deploy. Outside a deploy, it reopens a ready but fenced unplanned restart and
sends a Lykta alert. After three such restarts within an hour it stops reopening
and alerts that the service needs the operator. Every service boot stays fenced.

## Data and limits

Only identity hashes, stable random subject UUIDs, hashed sessions/grants and
monthly sample aggregates persist. No audio, dictionary, transcript or CloudKit
token is stored. Keep the current and previous two months of aggregates; expired
sessions and unused grants are pruned. Subject mappings remain for account and
future purchase ownership. SQLite pages are capped at 192 MiB; WAL checkpoints
and bounded pruning keep transient state small. The private supervisor caps
logs, the poller retains two executable artifacts and recovery points. The
one-MiB page reserve raises a fatal capacity incident before the page cap.
Startup checks the same reserve, so the service stays unavailable until space is
freed. Automatic restarts follow the private unit's delay and start-limit
policy; the operator may need to reset and restart a limited unit. The private
poller alerts the operator and never reopens a failed check. Unexpected
ledger/operator failures log a content-free error class/SQLite code, close
admission and exit nonzero after current requests finish or fail. Startup
recovery releases dangling holds; a failed settlement cannot block process exit.
The private poller applies the reopening policy above once readiness succeeds.

A transcription reserves at most 120 seconds, expires unclaimed after 30 seconds
and has a 180-second total deadline. Meter actual 16 kHz samples. Charge a
produced transcript or a client-caused failure of a claimed attempt, rounded
up to whole seconds with a one-second minimum; a provider 400 or 422 input
refusal costs exactly one second. Connection failures, router refusals, other
provider 4xx and 5xx, invalid 200 responses, pre-dispatch fences and service
crashes release the reservation. Never forward or meter
beyond a batch WAV's declared length or its grant limit. Incomplete uploads have
a cumulative floor of 8,000 parser-received PCM samples per second of
client-input waiting, after a ten-second grace. Waiting on upstream consumption
pauses this clock and is never classified as a client timeout. The periodic
check defeats silence and trickling, aborts as a client failure and settles
measured input, with the one-second minimum. Normal real-time capture
supplies 16,000 samples/second; batch uploads are faster. A completed upload
waiting for its result has no progress timer. Response-read cancellation retains
client-failure charging. Recovery transcription is a new admitted attempt.
Periods are UTC calendar months; clients render the returned reset instant
locally. The future Pro ceiling belongs in the same service policy; no StoreKit
purchase handling is implemented here.
