# Mumla access service

This program owns CloudKit-to-subject identity, opaque sessions, supported input,
monthly admission and sample accounting. The router owns provider credentials
and transport. Keep product policy here; do not add identity or allowance code
to SpeechKit or llm-router.

- Identity comes only from Apple's production `users/caller` response. Preserve
  the plain hash-to-UUID mapping. No App Attest, bootstrap, provider catalog or
  client-selected model belongs in launch scope.

- SQLite is the sole ledger; one exclusive process owns it. Admission and
  settlement are synchronous transactions. Spent plus active reservations never
  exceeds the admission policy snapshot. Crash recovery releases dangling holds
  and reports an incident; dispatch starts when Bun fetch pulls the rebuilt
  request body's first bytes, after a validated 44-byte WAV header. A claimed
  attempt the client fails, dispatched or not, charges measured input with a
  one-second minimum, and a provider 400 or 422 input refusal charges exactly
  one second, so no attempt an account causes is free. Fences and closed
  admission before dispatch, connection failures, other upstream refusals and
  invalid results never charge. Never
  restore a usage snapshot as an ordinary rollback.

- Sessions last 30 days, rotate atomically and cannot call inference. One-use
  grants cannot create sessions. Both are hashed at rest. The keyboard receives
  typed status only, never a credential. Pass authenticated sessions into store
  operations; grant insertion rechecks the token and expiry after its body read.

- Forward only validated 16 kHz mono PCM16 WAV with the fixed clean
  transcription definition. Rebuild multipart, meter actual samples and
  propagate cancellation to both sides. No upgrades, URLs, arbitrary prompts or
  generic proxy routes.

- Start fenced on every boot. The private deploy owner waits for live idle with
  admission open, takes a consistent backup, fences only when idle, replaces and
  checks before reopening. Enrollments have eight separate slots, a two-second
  body deadline and no idle hold; they can be interrupted and retried. Unused
  grants and undispatched claims do not count as live; an idle fence revokes
  unused grants and aborts undispatched claims with retryable 503 and no charge.
  Only dispatched uploads and a backup hold idle. A busy fence does not close
  admission. Public health returns 200 only when ready and open. No deploy
  credentials belong in CI.

- A runtime ledger/operator incident closes admission, drains current requests
  and exits nonzero; the private poller owns reopening ready/fenced unplanned
  restarts, alerting through Lykta, and stopping reopening after three such
  restarts within an hour. Keep health/operator routes outside the data-request
  cap. Check the four-request subject cap before the global pool. Grant body
  reads have a two-second deadline.

- Only enrollment requires Cloudflare's `CF-Connecting-IP` from the loopback
  tunnel. Missing IP and runtime CloudKit proof denial refuse that request and
  rate-limit incident logs; they never stop the service. Normalize IPv4-mapped
  IPv6, limit other IPv6 per /64 and more loosely per /48, and keep no shared
  enrollment budget an unauthenticated sender could exhaust. Startup checks the CloudKit API token without a user proof. Definite
  rejection is fatal; transient failure gates only enrollment, with shared
  on-demand backoff. Existing sessions and transcription stay available.
  The offline deployment check requires proven identity, returning ready false,
  identity unproven and retryable exit 75 otherwise. Runtime 401 authentication
  failure is a configuration incident, while 421 rejects the user's identity.

- Incomplete uploads have a cumulative half-real-time progress floor after ten
  seconds of waiting for client input; trickling cannot reset it. Count parser
  arrivals independently of upstream consumption and pause that clock under
  upstream backpressure. Header and first audio must arrive within three
  seconds. Upload cancellation owns every timer and both streams. Validate the
  first preamble bytes and Busboy's first closing delimiter, requiring CRLF then
  EOF.

- Keep config, operator values, real identity proofs and recovery snapshots
  private. Logs contain fixed codes and counts only. Do not log requests or
  URLs.

- Service dependency notices live here, outside the app-bundled root notices.
  The canonical `ci.yml` admission includes this service's check, tests and
  build.

- Use `bun install --frozen-lockfile`, `bun run check` and `bun test`. Synthetic
  HTTP tests prove protocol and lifecycle boundaries; they do not prove Apple's
  native exchange or production inference. Those live app/device gates remain
  required before launch.
