# Mumla Pro

Status: decided after two independent challenges; their findings and
dispositions are at the end. Extends [the access service](mumla-access-service.md),
whose "Later Pro integration" section set the constraints below.

## Goal and constraints

A user who runs low on or out of free minutes buys Mumla Pro on iPhone or iPad,
sees it on every device signed in to the same iCloud account, restores it, and
manages or cancels it. The access service stays the only authority on what an
account may use; a client never asserts Pro or chooses its limit.

- Free: 60 processing minutes per UTC calendar month per iCloud account.
- Pro: $5.99 a month or $49.99 a year through StoreKit, for 30 hours of
  dictation a month. Every surface, App Store metadata included, states the 30
  hours; none calls Pro unlimited. Yearly billing keeps monthly windows. Both
  limits are service configuration.
- An entitlement raises the same monthly limit; upgrades keep used minutes, and a
  downgrade blocks new admissions without canceling admitted work.
- The existing service subject UUID is StoreKit's `appAccountToken`.
- The Mac ships only as the Developer ID download and cannot sell through
  StoreKit; it shows the plan and links to the App Store.

## Ownership policy

Ownership derives only from Apple-signed data and the service's own records.
The service keeps one row per subscription, `(environment,
originalTransactionId)`, holding its latest signed state, its owner and the
transaction that named the owner.

1. **The latest transaction defines a subscription's state.** A transaction
   replaces the stored one when its purchase date is later (transaction ID
   breaks a tie) or, for the same transaction, when its `signedDate` is later.
   Replaying an older JWS, or an older transaction's refund, changes nothing.
2. **A purchase belongs to the subject its `appAccountToken` names.** The
   latest transaction that carries a token names the owner, ordered as in rule
   1 and kept apart from the state, so delivery order never decides ownership.
   The iOS app always purchases with the session's subject. A submitter whose subject the
   owner is not gets `409 purchase_owned_elsewhere`; a token that names no
   known subject entitles nobody.
3. **A transaction without a token inherits the subscription's owner.** This
   covers resubscriptions and offers redeemed outside the app. Only a
   subscription with no token anywhere goes to the first subject that submits
   one of its transactions, until a transaction with a token arrives.
4. **iCloud account changes do not move Pro.** Where StoreKit holds an
   entitlement that the service reports as owned elsewhere, the app replaces
   Get Pro with "belongs to another iCloud account" and Manage Subscription, so
   it never sells a crossgrade that would reach the other account. Transfers are
   outside launch scope. If support must move one, the operator calls Set App
   Account Token and the user taps Restore on the new device; whether StoreKit
   then returns the re-tokened transaction is unverified, and otherwise the move
   lands at the next renewal.
5. **Revocation ends access.** A refunded or revoked latest transaction stops
   entitling, including one stored before anyone claimed the subscription;
   admitted work continues under its grant. A reversed refund restores access
   through the newer signed transaction.
6. **One purchase, one account.** Family Sharing stays off (enabling it is
   irreversible), and only `inAppOwnershipType` `PURCHASED` entitles.
   Multiseat purchase is disabled, the products sell only on the App Store,
   and they are not promoted on the App Store page.
7. **Sandbox is accepted with its own ceiling.** App Review and TestFlight
   purchase in the sandbox against the production service without paying, and
   the iOS download links the public TestFlight group. A sandbox entitlement
   therefore raises the limit only to `sandboxProMonthlySeconds`, enough to
   review Pro but not a free substitute. Environment is part of the key; Xcode
   and local StoreKit testing are not Apple-signed and are refused.
8. **No billing grace period at launch.** Access ends at `expiresDate`; a
   recovered renewal arrives as a new transaction.

The limit is the larger of a private subject override and the plan's limit.

## How the service learns of entitlements

Both paths feed one store operation that verifies, then applies rule 1 inside
one `BEGIN IMMEDIATE` transaction, so duplicate, retried and reordered
deliveries converge.

- **Client submission.** `ProStore` sends each verified Pro-group
  transaction's `jwsRepresentation` to `POST /v1/purchases`: from
  `Transaction.updates` (purchases from the store view, renewals, refunds, and
  unfinished transactions once at launch), and from every subscription status
  in the group, revoked and expired included, at launch, foreground, Restore
  (`AppStore.sync` first) and whenever the paywall's status task reports. It
  finishes a transaction after a 200, a definitive 400 or a 409, and remembers
  each answer by its JWS, which changes with every re-signed state, so
  foregrounds do not resubmit unchanged states; concurrent deliveries of one
  JWS are submitted once. `MumlaAccess.accountGeneration` counts iCloud account
  changes: answers, conflicts and pending activations belong to one
  generation, and an answer that arrives after a change publishes nothing.
  While an entitling transaction is submitted the paywall shows "Activating
  Mumla Pro"; once the access client's bounded retries fail, it keeps the
  transaction unfinished and shows "Mumla Pro isn't active yet" with Try Again,
  which reconciles, as the next foreground does. A 409 for an entitling
  transaction shows the owned-elsewhere state until a full reconciliation finds
  none; a failed status lookup leaves it as it was. Get Pro stays hidden
  meanwhile.
- **App Store Server Notifications V2.** `POST /v1/app-store/notifications`
  applies a verified payload's `signedTransactionInfo` whatever the
  notification type: renewals, expiry, refunds and revocations while no device
  runs StoreKit, as for a Mac-only user. It answers 200 when the payload was
  applied or deliberately ignored (no transaction, other group or ownership
  type), 400 when verification fails and 503 when it could not decide. Apple
  retries any 40x or 50x five times over about a week in production and never in
  the sandbox; a retried 400 is harmless.
- **Replay.** `scripts/replay-notifications.ts` (operator) reads Get
  Notification History for a window (180 days in production, 30 in the sandbox)
  and posts each payload to the service's loopback listener, since the public
  edge admits only Apple; records reflect their original state, which rules 1
  and 2 make safe to replay in any order. The maintainer runs it after any
  period the endpoint was unreachable or answering 5xx, and on a report of a
  missing renewal or refund. It needs an In-App Purchase key from the operator's
  environment; whether the production host ever holds one is an open
  deployment decision.

Verification uses Apple's App Store Server Library behind one module that
returns Mumla's own types. It pins Apple Root CA - G3 (SHA-256
`63343ABF…653E9179`, committed as a public certificate) and checks the chain's
Apple OIDs, certificate validity at the payload's `signedDate`, the signature,
the bundle ID, the app Apple ID for Production, and the environment. It runs
offline: no OCSP request, no egress, no timeout to bound, and an old but
authentic JWS stays valid after Apple's signing certificate expires. The cost
is that a revoked Apple signing key would need a forward fix. The service then
requires the configured subscription group, type Auto-Renewable Subscription,
`PURCHASED` ownership, numeric transaction IDs and an expiry date.

## Service API and schema

| Endpoint | Authorization | Contract |
| --- | --- | --- |
| `POST /v1/purchases` | Session | Body `{"signed_transaction": "<JWS>"}`, at most 16 KiB with a two-second body deadline. 200 `{allowance}`; 400 `invalid_purchase`; 409 `purchase_owned_elsewhere`; 503 retryable |
| `POST /v1/app-store/notifications` | Public, Apple-signed body | `{"signedPayload": "<JWS>"}`, at most 64 KiB with a two-second body deadline, eight slots outside the data pool; the slot is taken before reading |

The allowance gains `plan` (`"free"` or `"pro"`) and `pro_limit_seconds`, the
production Pro limit that the offer states. Configuration gains required
`proMonthlySeconds`, `sandboxProMonthlySeconds`, `appStoreBundleId`,
`appStoreAppId` and `subscriptionGroupId`.

One STRICT table, created with `CREATE TABLE IF NOT EXISTS` on every open:
`subscriptions(environment, original_transaction_id, owner, transaction_id,
purchased, expires, revoked, signed)`, keyed by environment and original
transaction ID and indexed by owner. Its size is bounded by the number of
subscriptions, so nothing is pruned. `user_version` stays 1 and snapshot
validation accepts databases without the table.

**Pro is a forward-only boundary.** The previous executable rejects the new
configuration keys and would ignore purchases, so it is never a rollback target
once Pro ships: defects are fixed forward. The first Pro deploy's automatic
readiness fallback restores the previous artifact and its previous
configuration together, before any purchase exists. Apps treat a missing
`plan` as Pro not offered only so development builds keep working against the
pre-Pro service between merge and release; that branch goes once the first Pro
release is live.

## Identifiers

| Item | Value |
| --- | --- |
| Subscription group | `22248259`, reference name and en-US name "Mumla Pro" |
| Monthly | `emileberhard.WisprClone.ios.subscription.monthly` (Apple ID `6792479392`), one month, level 1 |
| Yearly | `emileberhard.WisprClone.ios.subscription.yearly` (Apple ID `6831377958`), one year, level 1 |

Both products give the same service at one level, so switching between them
takes effect at the next renewal. Both have Family Sharing off, multiseat off,
App Store distribution only, every territory the app sells in, and prices at
Apple's equalization of the US price, except Monthly in Sweden, the launch
market, at 59 kr. The apps reference only the group ID; the
service checks only the group; product IDs live in App Store Connect and
`Apple/StoreKit/MumlaPro.storekit`. The sandbox notification URL is the
production service's endpoint; the production URL is set once the endpoint has
passed acceptance, and a dev instance may hold the sandbox URL during that
acceptance while no Pro build is in TestFlight or App Review.

## Where Pro appears

- **iOS paywall** (`ProOfferView`, a sheet): `SubscriptionStoreView` for the
  group with localized StoreKit prices, Restore, terms and privacy links, and a
  header that states the 30 hours from `pro_limit_seconds`. It loads the
  account token first, so every purchase carries it.
- **iOS dictation strip**: when a Free account is out of minutes, tapping
  No Minutes Left opens the paywall.
- **iOS Account** (`ProPlanRows`, wrapping the allowance row): Free shows Get
  Mumla Pro and Restore Purchases; Pro shows Manage Subscription; activation
  shows its progress and Try Again; a subscription owned by another iCloud
  account says so and offers Manage Subscription. Its sheets and alert hang
  on the allowance row, the one row every state keeps: in a `Form`, modifiers
  on several rows attach to each row and present nothing. The toolbar's
  allowance ring opens Account.
- **Mac** (`ProStatusRow`): the menu and Settings show the plan. Free links to
  Mumla on the App Store for iPhone and iPad; Pro links to the App Store's
  subscription management.
- Pro's allowance reads as Mumla Pro, with remaining time shown only near the
  ceiling.

## Testing

Service tests sign synthetic transactions with a generated chain; the live
acceptance uses real sandbox purchases. `Apple/StoreKit/MumlaPro.storekit`
mirrors the products for local StoreKit testing: select it under the MumlaiOS
scheme's Run options. Its transactions are Xcode-signed, so the service refuses
them and the app finishes them; it exercises the paywall, not activation.

## Privacy

The service stores, per subscription, the environment, original and latest
transaction IDs, purchase, expiry, revocation and signing dates, the owning
subject and the transaction that named it, for as long as the service runs. Apps send the signed transaction
only. The App Store privacy label gains Purchases (Purchase History), linked to
the user, for App Functionality, and the iOS app's privacy manifest declares
the same.

## Alternatives rejected

- **A row per transaction with first-claim rows**: more state, a pruning rule
  whose retention had to outlive every stale JWS, and a correlated "latest"
  query; one row per subscription gives the same answers.
- **Online revocation checks**: an OCSP egress dependency and a timeout that
  could release capacity while work continued, and certificate validity judged
  at the current time would reject an old authentic JWS.
- **Notifications only**: a purchase would wait on Apple's delivery and could
  not report ownership conflicts to the buyer.
- **Client submission only**: a refund or lapse would go unseen until a device
  launches, and a Mac-only user would keep a lapsed Pro.
- **Per-request App Store Server API queries**: a long-lived key on the host,
  a per-dictation Apple dependency and rate limits, for what submissions and
  notifications deliver. The operator replay keeps the smallest recovery.
- **First claim owns the whole subscription forever**: a user who resubscribes
  under a new iCloud account would pay without receiving Pro.
- **Hand-written JWS verification**: Apple's library owns chain, OID and
  signature rules; hiding it behind one module keeps it replaceable.

## What becomes expensive to change

- Product and group identifiers are permanent once created.
- Every transaction carries a subject UUID forever; changing how subjects are
  identified means re-tokening subscriptions through Set App Account Token.
- Enabling Family Sharing cannot be undone; removing Apple Business or School
  distribution after approval cancels their subscribers.
- Refusing Sandbox later would break App Review and TestFlight purchases.
- The 30 hours, monthly windows and prices are customer promises; Apple's
  price-increase rules govern raises.
- The `subscriptions` table and the allowance's `plan` field that installed
  apps read.

## Sandbox verification

A sandbox purchase on a physical iPhone, against a development service reached
by both the app and Apple's sandbox notifications, confirmed:

- The paywall's purchase carries the subject token; the app's submission and
  Apple's notification both answer 200, the plan turns Pro and the paywall
  closes to Settings' Manage Subscription.
- Renewals repeat `appAccountToken` and keep `originalTransactionId`: each
  renewal updated the same row and named the same owner, whether its
  notification or the app's delivery arrived first.
- With the service's row removed, the next renewal notification, a foreground
  delivering a state the app had not submitted, and Restore after
  `AppStore.sync` each restored Pro.
- After a cancellation, the plan returned to Free at `expiresDate`, and the
  app offered Get Mumla Pro and Restore again.

Still unverified: whether a resubscription after lapse keeps the original ID;
both crossgrades at renewal; refund and refund reversal; and whether StoreKit
returns a re-tokened transaction after Set App Account Token and Restore.

## Challenge record

Two independent reviewers challenged the proposal before any product existed.
Both approved the identifiers.

| Finding | Disposition |
| --- | --- |
| Unclaimed refunds were discarded, so a pre-refund JWS could later grant Pro | Fixed: state is stored whatever its ownership (rules 1 and 5) |
| The previous executable rejects the new configuration, so rollback was not compatible | Pro is a forward-only boundary |
| Public TestFlight would give Pro without payment | Fixed: sandbox ceiling (rule 7) |
| Token-less renewals in an owned subscription had no rule | Fixed: inheritance (rule 3) |
| The paywall could sell a plan owned by another account | Fixed: owned-elsewhere state replaces Get Pro |
| A failed activation after payment had no visible recovery | Fixed: activating state, bounded retry, Retry |
| Missed notifications had no repair; sandbox never retries | Operator replay through Get Notification History |
| Support transfer had no path into the service | Out of launch scope; procedure and its unverified step recorded (rule 4). Disagreed with building a support operation now: no current caller |
| Online checks judge certificates at the current time | Offline verification; the suggested `Transaction.latest` retry code is then unnecessary |
| Notification body read lacked a deadline | Two-second deadline, slot taken before reading |
| The notification endpoint can be starved by slow bodies | Launch step: allow only Apple's `17.0.0.0/8` on that path at the edge |
| "Unlimited" wording risks App Review and consumer law | Copy states 30 hours everywhere |
| Multiseat is on by default for new subscriptions | Disabled on both, App Store only |
| First subscriptions must ship with an app version | Launch step for the maintainer, with review screenshot, notes and the standard EULA link in metadata |
| Apple retries 40x too | Recorded above |
| Promoted purchases would lack a token | Products are not promoted |
| Set both notification URLs together | Partly disagreed: the sandbox URL is set now so test notifications and sandbox purchases reach the endpoint once deployed; the production URL waits for acceptance |
| Separate `Transaction.unfinished` pass | Dropped; `Transaction.updates` delivers them at launch |

## Pre-merge review

Two reviewers read the implemented branch.

| Finding | Disposition |
| --- | --- |
| Ownership depended on delivery order when a token-less transaction arrived first | Fixed: the transaction that named the owner is kept apart from the state (rule 2), with a test of four delivery orders |
| Reconciliation skipped revoked states, and its answer cache could not tell a refund reversal from the original | Fixed: every status is submitted; answers are keyed by JWS |
| An answer could land after an iCloud account change | Fixed: account generations in `MumlaAccess` and `ProStore` |
| Owned elsewhere stayed after that subscription ended | Fixed: a full reconciliation clears it |
| Concurrent deliveries of one transaction raced | Fixed: one submission per JWS in flight |
| The paywall's token could outlive an account change | Fixed: it reloads on a new generation |
| Replay through the public origin meets the Apple-only edge rule | Fixed: the script accepts only a loopback origin and retries 503 |
| The previous executable cannot check Pro's configuration | Documented: the Pro boundary's pre-fence check uses the previous configuration |
| Unknown keys in Apple's body would be rejected and dropped after retries | Fixed: the notification route reads only `signedPayload` |
| `PurchaseVerifier`, `retry()`, `RestoreOutcome` and a token passthrough had no second use | Removed or collapsed |
| Remove the answer cache | Disagreed: keyed by JWS it skips only states the service already answered, saving a verified request on every foreground; Restore clears it |
| Feed the paywall's status task into reconciliation | Fixed |
| Subscription owners outlive a deleted subject | Disagreed for now: the service has no subject deletion; whatever adds one clears `owner` in the same transaction |
| The new session field makes each device enroll once more | Accepted: one proof per device; sessions are capped at 32 per subject with the oldest revoked, and enrollment 503s retry |
| Replay with eight posts in flight | Disagreed: serial replay leaves the eight notification slots to Apple's live deliveries |
