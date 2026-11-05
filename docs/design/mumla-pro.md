# Mumla Pro

Status: proposed, pending the independent challenge. Extends
[the access service](mumla-access-service.md), whose "Later Pro integration"
section set the constraints below.

## Goal and constraints

A user who runs low on or out of free minutes buys Mumla Pro on iPhone or iPad,
sees it on every device signed in to the same iCloud account, restores it, and
manages or cancels it. The access service stays the only authority on what an
account may use; a client never asserts Pro or chooses its limit.

- Free: 60 processing minutes per UTC calendar month per iCloud account.
- Pro: $6.99 a month or $49.99 a year through StoreKit, presented as unlimited
  with a disclosed fair-use ceiling of 30 hours a month. Yearly billing keeps
  monthly windows. Both caps are service configuration.
- An entitlement raises the same monthly limit; upgrades keep used minutes, and a
  downgrade blocks new admissions without canceling admitted work.
- The existing service subject UUID is StoreKit's `appAccountToken`.
- The Mac ships only as the Developer ID download and cannot sell through
  StoreKit; it shows the plan and links to the App Store.

## Ownership policy

Ownership derives only from Apple-signed data and the service's own records.

1. **A purchase belongs to the subject its `appAccountToken` names.** The iOS app
   always purchases with the session's subject. A signed transaction whose token
   names another subject entitles that subject, never the submitter, who gets
   `409 purchase_owned_elsewhere`. A token that names no known subject entitles
   nobody.
2. **A transaction without a token belongs to the first subject that submits
   it**, recorded permanently per `(environment, originalTransactionId)`. This
   covers subscriptions started outside the app, such as an offer code redeemed
   in the App Store. Later token-less transactions in that subscription follow
   the claim; notifications for an unclaimed one are ignored until a device
   claims it.
3. **One subscription entitles one iCloud account at a time.** Per
   `(environment, originalTransactionId)` only the most recent transaction, by
   purchase date, counts, as in StoreKit's `currentEntitlements`. A later
   transaction with another token, such as a resubscription after an iCloud
   account change, moves the entitlement; replaying an older JWS cannot bring
   back a superseded one.
4. **iCloud account changes do not move Pro.** Restore on another iCloud account
   shows that the subscription belongs to another iCloud account and offers
   Manage Subscription. There is no self-service transfer. If support must move
   one, the operator uses App Store Server API's Set App Account Token, which
   carries the new token into renewals; the service follows the newer signed
   data without database edits.
5. **Refunds and revocations end access at `revocationDate`.** Admitted work
   continues under its grant. A reversed refund restores access through the
   newer signed transaction.
6. **Family Sharing stays off** (enabling it is irreversible). Only
   `inAppOwnershipType` `PURCHASED` entitles. Multi-seat purchase is disabled and
   the products are sold only on the App Store, not to Apple Business or Apple
   School.
7. **Sandbox is accepted in production.** App Review and TestFlight purchase in
   the sandbox against the production service, so their purchases grant Pro with
   the same ceiling. TestFlight testers therefore get Pro without paying; the
   ceiling bounds it, and a measured abuse response is a reviewed change.
   Environment is part of every key, so a sandbox transaction never collides
   with a production one. Xcode and local StoreKit testing are not Apple-signed
   and are refused.
8. **No billing grace period at launch.** Access ends at `expiresDate`; a
   recovered renewal arrives as a new transaction.

The limit is the larger of a private subject override and the plan's limit.

## How the service learns of entitlements

Both paths feed one operation, `apply(signedTransaction)`, which is idempotent
and order-independent.

- **Client submission.** The iOS app sends the transaction's
  `jwsRepresentation` to `POST /v1/purchases` for every verified transaction in
  the Pro group from `Transaction.updates` (where StoreKit views deliver
  purchases), from `Transaction.unfinished` at launch, after Restore
  (`AppStore.sync`, then `currentEntitlements`), and at launch and foreground
  when the service reports Free while StoreKit holds an entitlement. It finishes
  a transaction after a 200 or a definitive 400 or 409; a 503 or network failure
  leaves it unfinished for the next launch.
- **App Store Server Notifications V2.** `POST /v1/app-store/notifications`
  verifies the signed payload and applies its `signedTransactionInfo`, whatever
  the notification type. This covers renewals, expiry, refunds and revocations
  while no device runs StoreKit, as for a Mac-only user. It returns 200 when the
  payload was applied or deliberately ignored (no transaction, unclaimed, other
  group), 400 when verification fails, and 503 when it could not decide, so
  Apple retries.

Verification uses Apple's App Store Server Library behind one service module
that returns Mumla's own types. It pins Apple Root CA - G3 (SHA-256
`63343ABF…653E9179`, committed as a public certificate), checks the chain's
Apple OIDs, the bundle ID, the app Apple ID for Production, and the
environment, with online revocation checks. A revocation-check outage is
retryable (503) and bounded by a timeout; it never affects already stored
entitlements or admission. The service then requires the configured
subscription group, type Auto-Renewable Subscription, `PURCHASED` ownership and
an expiry date.

Per `(environment, transactionId)` the service keeps the newest `signedDate`, so
duplicate, retried and reordered deliveries converge. Apple retries undelivered
notifications; a device's next launch reconciles through StoreKit. Missed
notifications for a user with no iOS device leave a lapsed renewal unseen until
an iOS launch or an operator replay from Get Notification History; the
service holds no App Store Server API key at launch.

## Service API and schema

| Endpoint | Authorization | Contract |
| --- | --- | --- |
| `POST /v1/purchases` | Session | Body `{"signed_transaction": "<JWS>"}`, at most 16 KiB with the two-second body deadline. 200 `{allowance}`; 400 `invalid_purchase`; 409 `purchase_owned_elsewhere`; 503 retryable |
| `POST /v1/app-store/notifications` | Public, Apple-signed body | `{"signedPayload": "<JWS>"}`, at most 64 KiB, eight separate slots outside the data pool |

The allowance gains `plan` (`"free"` or `"pro"`) and `pro_limit_seconds`. Apps
treat a missing `plan` as "Pro not offered", so a rolled-back service keeps
dictation working and hides Pro. Configuration gains required
`appStoreBundleId`, `appStoreAppId`, `subscriptionGroupId` and
`proMonthlySeconds`.

Two STRICT tables, created with `CREATE TABLE IF NOT EXISTS` on every open, keep
`user_version` 1 so the previous executable still opens the database and simply
ignores them; during such a rollback Pro users get the free limit. Snapshot
validation accepts databases without them.

- `purchase_claims(environment, original_transaction_id, subject)`: permanent
  first-claim rows for token-less subscriptions.
- `purchase_transactions(environment, transaction_id, original_transaction_id,
  subject, purchased, expires, revoked, signed)`: the newest signed state of each
  transaction and its resolved owner. `revoked` is null unless Apple revoked it.

Rows are pruned 90 days after `expires`, never by revocation date, so a stale
pre-refund JWS cannot outlive the record that supersedes it. Claims are never
pruned. Writes and the ownership decision run in one `BEGIN IMMEDIATE`
transaction.

## Identifiers

| Item | Value |
| --- | --- |
| Subscription group | `22248259`, renamed from "WisprClone Pro" to "Mumla Pro" |
| Monthly | `emileberhard.WisprClone.ios.subscription.monthly` (existing, never submitted), $6.99, level 1 |
| Yearly | `emileberhard.WisprClone.ios.subscription.yearly`, $49.99, level 1 |

Both products give the same service at one level, so switching between them
takes effect at the next renewal. The apps reference only the group ID; the
service checks only the group; product IDs live in App Store Connect and the
StoreKit configuration file. The sandbox notification URL is the production
service's notifications endpoint; the production URL is set at launch.

## Where Pro appears

- **iOS paywall** (`ProOfferView`, a sheet): `SubscriptionStoreView` for the
  group with localized StoreKit prices, Restore, terms and privacy links, and a
  header that states the fair-use ceiling from `pro_limit_seconds`.
- **iOS allowance card**: a Get Pro button when Free and running low or out,
  where the card already appears above the dictation pill and in Settings.
- **iOS Settings**: a plan section. Free shows Get Pro and Restore; Pro shows
  Manage Subscription; a subscription owned by another iCloud account says so
  and offers Manage Subscription.
- **Mac**: the menu and Settings show the plan. Free links to Mumla on the App
  Store for iPhone and iPad; Pro links to the App Store's subscription
  management.
- Pro's allowance reads as Mumla Pro, with remaining time shown only near the
  ceiling.

## Alternatives rejected

- **Notifications only**: a purchase would wait on Apple's delivery and could
  not report ownership conflicts to the buyer.
- **Client submission only**: a refund or lapse would go unseen until a device
  launches, and a Mac-only user would keep a lapsed Pro.
- **App Store Server API status queries**: adds a long-lived key, a per-request
  Apple dependency and rate limits, for what signed submissions and
  notifications already deliver.
- **First claim owns the whole subscription forever**: a user who resubscribes
  under a new iCloud account would pay without receiving Pro.
- **Hand-written JWS verification**: Apple's library owns chain, OID and
  revocation rules; hiding it behind one module keeps it replaceable.

## What becomes expensive to change

- Product and group identifiers are permanent once created.
- Every transaction carries a subject UUID forever; changing how subjects are
  identified means re-tokening subscriptions through Set App Account Token.
- Enabling Family Sharing cannot be undone.
- Refusing Sandbox later would break App Review and TestFlight purchases.
- The disclosed fair-use ceiling, monthly windows and price are customer
  promises; Apple's price-increase rules govern raises.
- Permanent first-claim rows, the additive tables and the allowance's `plan`
  field that installed apps read.

## Assumptions to verify

- Apple keeps `originalTransactionId` across renewals and resubscriptions in a
  group and repeats `appAccountToken` on renewals.
- Online revocation checks work from the service host through its egress.
- Apple's library runs under the pinned Bun runtime and its compiled single
  executable.
