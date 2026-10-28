# Canonical build and release

Mumla keeps its macOS menu-bar app, iOS app and keyboard, deployment floors,
all persisted identifiers and Production CloudKit data. This record owns the
project and delivery contracts; the access-service design owns inference policy.

The committed JSON Xcode project replaces Tuist. Shared xcconfigs own compiler
settings; target settings own their distinct identities and entitlements.
Synchronized source folders discover target-owned files; shared subsets retain
explicit membership. Package.resolved pins remote packages; GrantKit stays a
local package hydrated at one recorded revision using anonymous HTTPS on hosted
runners. For GrantKit development the same path can be a symlink to a working
checkout.

Project xcconfig references use `configurations`; target overrides use
`specialized-configurations` and list only specialized configurations. CI checks
every target and configuration with `xcodebuild -showBuildSettings`, using
non-secret markers in isolated copies of the configured xcconfigs. The probe
reuses resolved packages and never reads local credential overrides.

Push/PR CI compiles every shipping target and runs the existing macOS Swift
Testing suites on hosted Xcode runners. Signed release jobs start only after
admission checks an annotated, highest plain SemVer tag on main and passing CI
on its exact commit. Hosted Xcode archives unsigned, attaches the intended
entitlements, cloud-signs and verifies exports before uploading iOS. No lane
uploads the sandboxed Mac App Store build, which cannot create event taps or
synthetic paste; the Mac ships only through Developer ID. One job seeds the global build numbers; each upload lane selects its exact
new or previously uploaded build, which downstream jobs reuse. TestFlight retains the explicit assignment of the iOS build to the external
groups and its beta review.
App Store preparation selects the exact reserved iOS build, captures new
screenshots and stops before review with manual release.

The unsandboxed Developer ID channel is the Mac's only distribution, because
only it can create event taps and synthetic paste. Its archive, notarization and publication run in the private
`mumla-deploy` repository after hosted admission, in parallel with hosted
TestFlight archives. The public release dispatches only its immutable version,
source commit, reserved Developer ID build, and source run/attempt. An
authenticated preflight checks private workflow availability before number
selection or App Store uploads. Private hosted admission verifies the source
repository, annotated newest tag on main, passing push CI, successful admission
and number selection, and the numbers job's bounded reservation receipt. A
failed-jobs rerun can copy successful jobs with the current attempt number, so
job metadata is not artifact provenance. Admission lists this source run's
artifacts and selects the highest non-expired `mac-reservation-N` with N no
higher than the requesting attempt. That attempt must have one bounded receipt,
whose full repository/version/commit/build/source-run identity and original
attempt N must match. A malformed or mismatched selected receipt fails without
falling back to an older one. The requesting current attempt is verified
separately against the source run. Only then may the private
signing runner check out that commit and use its existing key and profile.
The marketing version matches every channel; Developer ID and TestFlight build
numbers may differ. GitHub release publication joins the iOS and Developer ID lanes.

The public job waits for the exact dispatched private run, verifies its bounded
receipt, and independently hashes the DMG at the fixed download origin. Receipt
and public manifest must agree on source commit, version, build and digest;
the receipt also binds both runs and the source attempt. Publication checks the
signed app's version/build. A failed-jobs retry reuses the same reservation and
published bytes. Any existing marketing version must match the admitted
commit and build exactly before its published bytes can be reused and verified.
Rerunning all jobs with a different reservation requires a new patch; it cannot
replace an existing version. A version rollback is rejected.
A missing private repository or handoff credential blocks the release; it never falls back to public self-hosted jobs.
Local macOS development keeps its existing signing identity and Production data.

Keeping Tuist/Fastlane as a second release path was rejected: it duplicates
version/signing policy and cannot prove the replacement. Moving product source
folders or extracting a Core package adds no platform boundary here, so the
working layout stays. Developer ID cannot use App Store cloud signing.

The JSON format requires Xcode 27; .xcode-version pins the available hosted
27.2 toolchain. A changed signing capability can invalidate local/Developer ID
profiles and must be repaired deliberately. The expensive boundaries remain
bundle/App Group/CloudKit/KVS identities and retained user data; none changes.

Release retries fence each platform's observable upload step independently.
A failed-jobs rerun selects the exact existing version/build, including dotted
historical build numbers, and skips another archive/export/upload. An uncertain
upload waits at most 15 minutes for App Store Connect, then stops for inspection.
The build number selected by each TestFlight lane is authoritative downstream;
new builds keep the global integer train above every historical leading component.
Locked package resolution precedes builds using the same derived-data directory.
Screenshot placement completes only at ACTIVE or a PARENT_* state; other states
remain pending and FAILED remains an error.

Cutover requires the private deployment workflow, private signing-runner
registration, source-read and dispatch credentials, and protected environments
before the next tag. The public repository has no self-hosted runner access.
The current download origin, app identities, Production CloudKit data and
installed-user behavior remain unchanged. Operator details live only in the
private deployment repository.

## Service-first distribution

The access service shares the annotated tag's version and exact commit. Its
private VPS poller admits the public tag/main/CI/release-admission identity,
prepares while admission stays open, waits up to 900 seconds for idle, atomically
fences only when idle, then switches and checks the new executable. A failed
readiness check restores the compatible prior executable without restoring an
old usage snapshot. Operator configuration, polling and deployment stay in the
private deployment repository; public Actions gain no server authority.

App archives, cloud-signing checks and Developer ID notarization proceed in
parallel with deployment. Before TestFlight upload, review/distribution, App
Store preparation or DMG publication, the shared health helper waits at most
30 minutes for HTTP 200 with the exact version and commit at the HTTPS
`MumlaAccessOrigin` in the source's iOS Info.plist, the origin the apps ship
with. That bound exceeds the 900-second idle wait.
Every service starts fenced and reports 503 until ready and reopened, so merely
starting the candidate cannot release apps before deployment succeeds. Health
queries are read-only, TLS-verified, do not follow redirects, and have bounded
body size and per-request time. A health timeout leaves app artifacts unshipped
and requires inspecting the private deployment before retrying failed jobs.
There is no service dispatch or second receipt format: public health is the
service receipt. The Developer ID's existing artifact receipt remains separate.

Release apps carry the CloudKit Web Services API token, which names the
container to CloudKit and proves no user; every shipped app exposes it, but the
repository does not. The hosted iOS lane and the private Developer ID workflow
write their environment's `MUMLA_CLOUDKIT_API_TOKEN` into the ignored
`Local.xcconfig`, and `scripts/check-access-configuration` stops a build whose
Info.plist lacks the origin or token.

The VPS polling mechanism follows the established gateway deployment boundary.
Routing a second dispatch through the signing host was rejected because the
service host already owns its process and state. Serializing app archives behind
service readiness was rejected because only distribution depends on that state.
