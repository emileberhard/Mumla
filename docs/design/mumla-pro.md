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
- Pro: $6.99 a month or $49.99 a year through StoreKit, for 30 hours of
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
originalTransactionId)`, holding its latest signed state and its owner.

1. **The latest transaction defines a subscription's state.** A transaction
   replaces the stored one when its purchase date is later (transaction ID
   breaks a tie) or, for the same transaction, when its `signedDate` is later.
   Replaying an older JWS, or an older transaction's refund, changes nothing.
2. **A purchase belongs to the subject its `appAccountToken` names.** The iOS app
   always purchases with the session's subject. A submitter whose subject the
   owner is not gets `409 purchase_owned_elsewhere`; a token that names no
   known subject entitles nobody.
3. **A transaction without a token inherits the subscription's owner.** This
   covers resubscriptions and offers redeemed outside the app. An older
   transaction's token names the owner of a subscription that has none yet.
   Only a subscription with no owner at all goes to the first subject that
   submits one of its transactions, permanently.
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
  unfinished transactions once at launch), and from the group's subscription
  status at launch, foreground, Restore (`AppStore.sync` first) and whenever
  the paywall sees the status change. It finishes a transaction after a 200, a
  definitive 400 or a 409, and remembers each answered transaction until the
  iCloud account changes, so foregrounds do not resubmit it. While a
  submission runs the paywall shows "Activating Mumla Pro"; once the access
  client's bounded retries fail, it keeps the transaction unfinished and shows
  "Mumla Pro isn't active yet" with Try Again, which the next foreground also
  retries. Get Pro stays hidden meanwhile.
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
  and posts each payload to the endpoint above; records reflect their original
  state, which rule 1 makes safe to replay. The maintainer runs it after any
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
Apple's equalization of the US price. The apps reference only the group ID; the
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
- **iOS Account** (`ProPlanRows`, under the allowance): Free shows Get
  Mumla Pro and Restore Purchases; Pro shows Manage Subscription; activation
  shows its progress and Try Again; a subscription owned by another iCloud
  account says so and offers Manage Subscription. The toolbar's allowance ring
  opens Account.
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
transaction IDs, purchase, expiry, revocation and signing dates, and the owning
subject, for as long as the service runs. Apps send the signed transaction
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

## Assumptions to verify in the sandbox

- Renewals repeat `appAccountToken` and keep `originalTransactionId`; whether a
  resubscription after lapse keeps the same original ID.
- Both crossgrades take effect at renewal; refund, refund reversal and
  reordered delivery converge.
- StoreKit returns a re-tokened transaction after Set App Account Token and
  Restore.

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
