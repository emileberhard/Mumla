import { Database } from "bun:sqlite";
import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { SignedTransaction } from "../src/appstore";
import { AccessError, sampleRate } from "../src/protocol";
import { AccessStore, validateSnapshot } from "../src/store";
import {
  notification,
  sign,
  syntheticVerifier,
  transaction,
} from "./appstore-fixture";

const resources: (() => void)[] = [];
afterEach(() => {
  for (const cleanup of resources.splice(0).reverse()) cleanup();
});

const day = 24 * 60 * 60 * 1000;
const now = Date.parse("2026-11-15T12:00:00Z");
const policy = {
  freeMonthlySeconds: 3600,
  proMonthlySeconds: 108_000,
  sandboxProMonthlySeconds: 7200,
  subjectOverrides: {} as Record<string, number>,
};

function open(overrides: Record<string, number> = {}) {
  const directory = mkdtempSync(join(tmpdir(), "mumla-purchase-test-"));
  resources.push(() => rmSync(directory, { recursive: true, force: true }));
  const path = join(directory, "access.sqlite");
  const store = new AccessStore(
    path,
    { ...policy, subjectOverrides: overrides },
    "initialize",
  );
  resources.push(() => store.close());
  return { store, path };
}

function account(store: AccessStore, identity: string, at = now) {
  const enrolled = store.enroll(identity, at);
  return {
    subject: enrolled.subject,
    session: store.authenticate(enrolled.token, at),
  };
}

function signed(fields: Partial<SignedTransaction> = {}): SignedTransaction {
  return {
    environment: "Production",
    transactionId: "1001",
    originalTransactionId: "1000",
    appAccountToken: null,
    purchased: now - day,
    expires: now + 29 * day,
    revoked: null,
    signed: now,
    ...fields,
  };
}

function rejection(work: () => unknown) {
  try {
    work();
  } catch (error) {
    if (error instanceof AccessError) return error.code;
    throw error;
  }
  return undefined;
}

async function rejectionOf(work: Promise<unknown>) {
  try {
    await work;
  } catch (error) {
    if (error instanceof AccessError) return error.code;
    throw error;
  }
  return undefined;
}

test("a purchase entitles the subject its account token names, never another submitter", () => {
  const { store } = open();
  const buyer = account(store, "buyer");
  const other = account(store, "other");
  const purchase = signed({ appAccountToken: buyer.subject });
  expect(rejection(() => store.purchase(other.session, purchase, now))).toBe(
    "purchase_owned_elsewhere",
  );
  expect(store.access(buyer.session, now).plan).toBe("pro");
  expect(store.purchase(buyer.session, purchase, now)).toMatchObject({
    plan: "pro",
    limit_seconds: 108_000,
    pro_limit_seconds: 108_000,
  });
  expect(store.access(other.session, now).plan).toBe("free");
  expect(
    rejection(() =>
      store.purchase(
        other.session,
        signed({
          transactionId: "2001",
          originalTransactionId: "2000",
          appAccountToken: "00000000-0000-4000-8000-000000000000",
        }),
        now,
      ),
    ),
  ).toBe("purchase_owned_elsewhere");
});

test("the first subject to submit a token-less subscription keeps it", () => {
  const { store } = open();
  const first = account(store, "first");
  const second = account(store, "second");
  store.notify(signed(), now);
  expect(store.access(first.session, now).plan).toBe("free");
  expect(store.purchase(first.session, signed(), now).plan).toBe("pro");
  const renewal = signed({
    transactionId: "1002",
    purchased: now + 29 * day,
    expires: now + 59 * day,
    signed: now + 29 * day,
  });
  expect(rejection(() => store.purchase(second.session, renewal, now))).toBe(
    "purchase_owned_elsewhere",
  );
  store.notify(renewal, now + 29 * day);
  expect(store.access(first.session, now + 40 * day).plan).toBe("pro");
  expect(store.access(second.session, now + 40 * day).plan).toBe("free");
});

test("a token-less transaction inherits its subscription's owner", () => {
  const { store } = open();
  const buyer = account(store, "buyer");
  const other = account(store, "other");
  store.purchase(
    buyer.session,
    signed({ appAccountToken: buyer.subject }),
    now,
  );
  const resubscribed = signed({
    transactionId: "1002",
    purchased: now + 40 * day,
    expires: now + 70 * day,
    signed: now + 40 * day,
  });
  expect(
    rejection(() => store.purchase(other.session, resubscribed, now)),
  ).toBe("purchase_owned_elsewhere");
  store.notify(resubscribed, now + 40 * day);
  expect(store.access(buyer.session, now + 50 * day).plan).toBe("pro");
  expect(store.access(other.session, now + 50 * day).plan).toBe("free");
});

test("an older in-app transaction names the owner of a token-less subscription", () => {
  const { store } = open();
  const buyer = account(store, "buyer");
  const other = account(store, "other");
  store.notify(signed({ transactionId: "1002", signed: now + 1 }), now);
  store.notify(
    signed({
      appAccountToken: buyer.subject,
      purchased: now - 31 * day,
      expires: now - day,
    }),
    now,
  );
  expect(rejection(() => store.purchase(other.session, signed(), now))).toBe(
    "purchase_owned_elsewhere",
  );
  expect(store.access(buyer.session, now).plan).toBe("pro");
});

test("the latest transaction that names an account owns the subscription whatever the delivery order", () => {
  const first = signed({ purchased: now - 3 * day, expires: now - 2 * day });
  const second = signed({
    transactionId: "1002",
    purchased: now - 2 * day,
    expires: now - day,
  });
  const latest = signed({ transactionId: "1003" });
  for (const order of [
    [first, second, latest],
    [latest, first, second],
    [latest, second, first],
    [second, latest, first],
  ]) {
    const { store } = open();
    const a = account(store, "a");
    const b = account(store, "b");
    const token = { "1001": a.subject, "1002": b.subject, "1003": null };
    for (const delivered of order)
      store.notify(
        {
          ...delivered,
          appAccountToken: token[delivered.transactionId as keyof typeof token],
        },
        now,
      );
    expect(store.access(b.session, now).plan).toBe("pro");
    expect(store.access(a.session, now).plan).toBe("free");
  }
});

test("a Sandbox purchase raises the limit only to the Sandbox ceiling", () => {
  const { store } = open();
  const tester = account(store, "tester");
  expect(
    store.purchase(
      tester.session,
      signed({ environment: "Sandbox", appAccountToken: tester.subject }),
      now,
    ),
  ).toMatchObject({
    plan: "pro",
    limit_seconds: 7200,
    pro_limit_seconds: 108_000,
  });
  store.purchase(
    tester.session,
    signed({
      transactionId: "2001",
      originalTransactionId: "2000",
      appAccountToken: tester.subject,
    }),
    now,
  );
  expect(store.access(tester.session, now).limit_seconds).toBe(108_000);
});

test("a refund that arrives before anyone claims a subscription still binds the claim", () => {
  const { store } = open();
  const claimant = account(store, "claimant");
  store.notify(signed({ revoked: now - 1, signed: now + 10 }), now);
  expect(store.purchase(claimant.session, signed(), now).plan).toBe("free");
});

test("only a subscription's latest transaction entitles, so a new token moves Pro", () => {
  const { store } = open();
  const before = account(store, "before");
  const after = account(store, "after");
  store.notify(
    signed({ appAccountToken: before.subject, expires: now + 2 * day }),
    now,
  );
  expect(store.access(before.session, now).plan).toBe("pro");
  store.notify(
    signed({
      transactionId: "1002",
      appAccountToken: after.subject,
      purchased: now - day / 2,
      expires: now + 30 * day,
    }),
    now,
  );
  expect(store.access(before.session, now).plan).toBe("free");
  expect(store.access(after.session, now).plan).toBe("pro");
  store.notify(
    signed({
      appAccountToken: before.subject,
      expires: now + 2 * day,
      signed: now + 1,
    }),
    now,
  );
  expect(store.access(before.session, now).plan).toBe("free");
});

test("revocation ends access, a stale replay cannot undo it, and a reversal restores it", () => {
  const { store } = open();
  const buyer = account(store, "buyer");
  const purchase = signed({ appAccountToken: buyer.subject });
  store.purchase(buyer.session, purchase, now);
  store.notify({ ...purchase, revoked: now - 1, signed: now + 10 }, now);
  expect(store.access(buyer.session, now).plan).toBe("free");
  expect(store.purchase(buyer.session, purchase, now).plan).toBe("free");
  store.notify({ ...purchase, signed: now + 20 }, now);
  expect(store.access(buyer.session, now).plan).toBe("pro");
});

test("Pro raises the same month's limit, keeps used minutes, and lapses at expiry", () => {
  const { store } = open();
  const buyer = account(store, "buyer");
  for (const _ of [1, 2]) {
    const grant = store.reserve(buyer.session, 1800, now);
    store.settle(store.claim(grant.token, now), 1800 * sampleRate, true);
  }
  expect(rejection(() => store.reserve(buyer.session, 60, now))).toBe(
    "allowance_exhausted",
  );
  const expires = now + day;
  store.purchase(
    buyer.session,
    signed({ appAccountToken: buyer.subject, expires }),
    now,
  );
  const upgraded = store.access(buyer.session, now);
  expect(upgraded).toMatchObject({
    plan: "pro",
    used_seconds: 3600,
    limit_seconds: 108_000,
  });
  expect(store.reserve(buyer.session, 60, now).audio_limit_samples).toBe(
    60 * sampleRate,
  );
  expect(store.access(buyer.session, expires).plan).toBe("free");
  expect(rejection(() => store.reserve(buyer.session, 60, expires))).toBe(
    "allowance_exhausted",
  );
});

test("an override larger than Pro wins whatever the plan", () => {
  const directory = mkdtempSync(join(tmpdir(), "mumla-purchase-test-"));
  resources.push(() => rmSync(directory, { recursive: true, force: true }));
  const path = join(directory, "access.sqlite");
  const initial = new AccessStore(path, policy, "initialize");
  const subject = initial.enroll("operator", now).subject;
  initial.close();
  const store = new AccessStore(
    path,
    { ...policy, subjectOverrides: { [subject]: 200_000 } },
    "open",
  );
  resources.push(() => store.close());
  const operator = account(store, "operator");
  expect(store.access(operator.session, now)).toMatchObject({
    plan: "free",
    limit_seconds: 200_000,
  });
  expect(
    store.purchase(operator.session, signed({ appAccountToken: subject }), now),
  ).toMatchObject({ plan: "pro", limit_seconds: 200_000 });
});

test("a database from before Pro passes snapshot validation and gains the tables on open", () => {
  const directory = mkdtempSync(join(tmpdir(), "mumla-purchase-test-"));
  resources.push(() => rmSync(directory, { recursive: true, force: true }));
  const path = join(directory, "access.sqlite");
  new AccessStore(path, policy, "initialize").close();
  {
    using db = new Database(path);
    db.exec("DROP TABLE subscriptions; PRAGMA journal_mode = DELETE;");
  }
  validateSnapshot(path);
  const store = new AccessStore(path, policy, "open");
  const buyer = account(store, "buyer");
  expect(
    store.purchase(
      buyer.session,
      signed({ appAccountToken: buyer.subject }),
      now,
    ).plan,
  ).toBe("pro");
  store.close();
  using db = new Database(path, { readonly: true });
  expect(db.query("PRAGMA user_version").get()).toEqual({ user_version: 1 });
});

test("the verifier accepts the configured group's purchased subscriptions only", async () => {
  const verifier = syntheticVerifier();
  const token = "6F9619FF-8B86-4011-B42D-00C04FC964FF";
  expect(
    await verifier.transaction(
      sign(transaction({ appAccountToken: token, revocationDate: 1 })),
    ),
  ).toMatchObject({
    environment: "Sandbox",
    transactionId: "2000000000000001",
    originalTransactionId: "2000000000000001",
    appAccountToken: token.toLowerCase(),
    revoked: 1,
  });
  for (const fields of [
    { subscriptionGroupIdentifier: "20000002" },
    { inAppOwnershipType: "FAMILY_SHARED" },
    { type: "Non-Consumable" },
    { environment: "Xcode" },
    { bundleId: "example.other.app" },
    { expiresDate: undefined },
    { appAccountToken: "not-a-uuid" },
  ])
    expect(
      await rejectionOf(verifier.transaction(sign(transaction(fields)))),
    ).toBe("invalid_purchase");
  const valid = sign(transaction());
  expect(
    await rejectionOf(verifier.transaction(`${valid.slice(0, -6)}AAAAAA`)),
  ).toBe("invalid_purchase");
  expect(
    await rejectionOf(
      verifier.transaction(sign(transaction({ environment: "Production" }))),
    ),
  ).toBeUndefined();
});

test("notifications yield their subscription transaction or nothing", async () => {
  const verifier = syntheticVerifier();
  expect(await verifier.notification(notification(undefined))).toBe(null);
  expect(
    await verifier.notification(
      notification(sign(transaction({ inAppOwnershipType: "FAMILY_SHARED" }))),
    ),
  ).toBe(null);
  expect(
    await verifier.notification(notification(sign(transaction()))),
  ).toMatchObject({ transactionId: "2000000000000001" });
  expect(
    await rejectionOf(
      verifier.notification(notification(sign(transaction()), "Production")),
    ),
  ).toBe("invalid_purchase");
  expect(await rejectionOf(verifier.notification("a.b.c"))).toBe(
    "invalid_purchase",
  );
});
