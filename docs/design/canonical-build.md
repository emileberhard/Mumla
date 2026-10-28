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
only it can create event taps and synthetic paste. Its hosted `developer-id`
job runs in parallel with the TestFlight lane, in the same tag-limited
environment. It imports the environment's Developer ID Application p12 into a
temporary keychain, archives unsigned, signs ad hoc with the Developer ID
entitlements and the hardened runtime, and exports with method `developer-id`
and manual signing, using the environment's "Mumla Developer ID CI" profile and
the identity of the certificate it names. The export must keep every
entitlement and the runtime flag. The job
then signs the DMG with the same identity, a secure timestamp and its own
identifier, notarizes only the DMG, the outermost container, and staples it.
An always-run step deletes the keychain before the artifact upload. The
marketing version matches every channel; Developer ID and TestFlight build
numbers may differ. The TestFlight upload waits for the `developer-id` job to
succeed, so a Mac failure ships no channel and "Re-run failed jobs" resumes
both. GitHub release publication joins the iOS and Developer ID lanes,
rechecks the access service and attaches the DMG as `Mumla.dmg`.

The release is created as a draft with the DMG, checked against the built
digest and only then published, so the newest release never lacks its DMG. A
retry replaces the DMG only while the release is a draft; a published release
must already carry an uploaded `Mumla.dmg` with the attempt's digest, and
anything else ships as the next patch. A version rollback is rejected because
only the newest version tag is marked Latest. The download page links to the
Latest release's `Mumla.dmg` and needs no per-release publication.

App Store Connect API keys cannot cloud sign Developer ID: Apple confirms it
as a known bug, and the release's own export failed with a cloud signing
permission error even for an Admin team key, and automatic signing tries
the cloud certificate even with a local identity. So the job holds a dedicated
Developer ID Application certificate (G2, created 2026-10-28, expires
2027-11-27) that signs nothing else. It uses one of the team's five Developer
ID Application certificates, and local signing keeps its own. A private
signing runner was rejected: it made every release depend on one Mac, a
cross-repository dispatch and personal access tokens. The p12 is the one
secret that can sign Mac code under the team's name, and its only remedy,
revocation, breaks every DMG it signed. The tag-only environment that already
guards the Admin App Store Connect key holds it, and only the `developer-id`
job reads it.

If the p12 or its password may have leaked, delete both environment secrets,
then have the Account Holder ask Apple to revoke that certificate at
`product-security@apple.com`; Developer ID certificates cannot be revoked in
the developer account. Revocation stops installation and launch of every DMG
it signed, so create a new certificate and ship the next patch with it
straight away. Before the certificate expires, create its replacement and
update both secrets and the profile; DMGs signed earlier keep working through
their secure timestamps, and the Developer ID profile is valid for 18 years. A
capability change invalidates the profile: recreate it for the same
certificate and update the `DEVELOPER_ID_PROFILE` secret.
Local macOS development keeps its existing signing identity and Production data.

Keeping Tuist/Fastlane as a second release path was rejected: it duplicates
version/signing policy and cannot prove the replacement. Moving product source
folders or extracting a Core package adds no platform boundary here, so the
working layout stays.

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

Releases run only on GitHub-hosted runners with the tag-limited `testflight`
environment. The download origin, app identities, Production CloudKit data and
installed-user behavior remain unchanged. Operator details live only in the
private deployment repository.

## Service-first distribution

The access service shares the annotated tag's version and exact commit. Its
private VPS poller detects new tags anonymously with `git ls-remote`, then
spends public API reads only on a new tag to confirm the release workflow's
`admit` job passed for that exact tag and commit; a rejected tag never deploys.
It prepares while admission stays open, waits up to 900 seconds for idle, atomically
fences only when idle, then switches and checks the new executable. A failed
readiness check restores the compatible prior executable without restoring an
old usage snapshot. Operator configuration, polling and deployment stay in the
private deployment repository; public Actions gain no server authority.

App archives, signing checks and Developer ID notarization proceed in
parallel with deployment. Before TestFlight upload, review/distribution, App
Store preparation or DMG publication, the shared health helper waits at most
30 minutes for HTTP 200 with the exact version and commit at the HTTPS
`MumlaAccessOrigin` in the source's iOS Info.plist, the origin the apps ship
with. That bound exceeds the 900-second idle wait.
Every service starts fenced and reports 503 until ready and reopened, so merely
starting the candidate cannot release apps before deployment succeeds. Health
queries are read-only, TLS-verified, do not follow redirects, and have bounded
body size and per-request time. A health timeout leaves app artifacts unshipped
and requires inspecting the VPS deployment before retrying failed jobs.
There is no service dispatch or second receipt format: public health is the
service receipt.

Release apps carry the CloudKit Web Services API token, which names the
container to CloudKit and proves no user; every shipped app exposes it, but the
repository does not. The hosted iOS and Developer ID lanes write their environment's `MUMLA_CLOUDKIT_API_TOKEN` into the ignored
`Local.xcconfig`, and `scripts/check-access-configuration` stops a build whose
Info.plist lacks the origin or token.

The VPS polling mechanism follows the established gateway deployment boundary.
Routing a second dispatch through the signing host was rejected because the
service host already owns its process and state. Serializing app archives behind
service readiness was rejected because only distribution depends on that state.
