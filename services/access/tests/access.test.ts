import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { sampleRate, sessionLifetimeMs } from "../src/protocol";
import { AccessStore, validateSnapshot } from "../src/store";

const resources: (() => void)[] = [];
afterEach(() => {
  for (const cleanup of resources.splice(0).reverse()) cleanup();
});

function database(seconds: number) {
  const directory = mkdtempSync(join(tmpdir(), "mumla-access-test-"));
  resources.push(() => rmSync(directory, { recursive: true, force: true }));
  const path = join(directory, "access.sqlite");
  const policy = { freeMonthlySeconds: seconds, subjectOverrides: {} };
  new AccessStore(path, policy, "initialize").close();
  return { path, policy };
}
const october = Date.parse("2026-10-31T23:59:50Z");

test("devices share one allowance; reservation contention differs from exhaustion", () => {
  const { path, policy } = database(2);
  using store = disposable(new AccessStore(path, policy, "open"));
  const phone = store.value.enroll("apple-account-a", october);
  const mac = store.value.enroll("apple-account-a", october);
  expect(phone.subject).toBe(mac.subject);
  const first = store.value.reserve(
    store.value.authenticate(phone.token, october),
    600,
    october,
  );
  expect(first.audio_limit_samples).toBe(32_000);
  expect(() =>
    store.value.reserve(
      store.value.authenticate(mac.token, october),
      1,
      october,
    ),
  ).toThrow("allowance_busy");
  const grant = store.value.claim(first.token, october);
  expect(() => store.value.claim(first.token, october)).toThrow(
    "invalid_grant",
  );
  store.value.settle(grant, sampleRate + 1, true);
  expect(
    store.value.access(store.value.authenticate(mac.token, october), october)
      .used_seconds,
  ).toBe(2);
  expect(() =>
    store.value.reserve(
      store.value.authenticate(mac.token, october),
      1,
      october,
    ),
  ).toThrow("allowance_exhausted");
  expect(
    store.value.access(
      store.value.authenticate(mac.token, Date.parse("2026-11-01T00:00:01Z")),
      Date.parse("2026-11-01T00:00:01Z"),
    ).used_seconds,
  ).toBe(0);
  const other = store.value.enroll("apple-account-b", october);
  expect(other.subject).not.toBe(phone.subject);
  expect(other.allowance.used_seconds).toBe(0);
});

test("rotation revokes the old session without invalidating an admitted upload", () => {
  const { path, policy } = database(60);
  using store = disposable(new AccessStore(path, policy, "open"));
  const original = store.value.enroll("apple-account", october);
  const grant = store.value.reserve(
    store.value.authenticate(original.token, october),
    5,
    october,
  );
  const pending = store.value.authenticate(original.token, october);
  const rotated = store.value.renew(
    store.value.authenticate(original.token, october + 1),
    october + 1,
  );
  expect(rotated.subject).toBe(original.subject);
  expect(() => store.value.reserve(pending, 5, october + 2)).toThrow(
    "invalid_session",
  );
  expect(() =>
    store.value.access(
      store.value.authenticate(original.token, october + 1),
      october + 1,
    ),
  ).toThrow("invalid_session");
  store.value.settle(store.value.claim(grant.token, october + 2), 16_000, true);
  expect(
    store.value.access(
      store.value.authenticate(rotated.token, october + 3),
      october + 3,
    ).used_seconds,
  ).toBe(1);
  store.value.revoke(
    store.value.authenticate(rotated.token, october + 4),
    october + 4,
  );
  expect(() =>
    store.value.access(
      store.value.authenticate(rotated.token, october + 5),
      october + 5,
    ),
  ).toThrow("invalid_session");
  const fresh = store.value.enroll("apple-account", october + 5);
  expect(fresh.subject).toBe(original.subject);
  expect(() =>
    store.value.access(
      store.value.authenticate(fresh.token, october + sessionLifetimeMs + 6),
      october + sessionLifetimeMs + 6,
    ),
  ).toThrow("invalid_session");
});

test("cross-month settlement stays in admission month; expired unused grant releases", () => {
  const { path, policy } = database(10);
  using store = disposable(new AccessStore(path, policy, "open"));
  const session = store.value.enroll("apple-account", october);
  const first = store.value.reserve(
    store.value.authenticate(session.token, october),
    10,
    october,
  );
  const admitted = store.value.claim(first.token, october);
  const nextMonth = Date.parse("2026-11-01T00:00:01Z");
  expect(
    store.value.access(
      store.value.authenticate(session.token, nextMonth),
      nextMonth,
    ).used_seconds,
  ).toBe(0);
  store.value.settle(admitted, 16_000, true);
  expect(
    store.value.access(
      store.value.authenticate(session.token, october),
      october,
    ).used_seconds,
  ).toBe(1);
  const second = store.value.reserve(
    store.value.authenticate(session.token, nextMonth),
    10,
    nextMonth,
  );
  expect(
    store.value.access(
      store.value.authenticate(session.token, nextMonth),
      nextMonth,
    ).used_seconds,
  ).toBe(0);
  expect(
    store.value.access(
      store.value.authenticate(session.token, nextMonth + 30_001),
      nextMonth + 30_001,
    ).reserved_seconds,
  ).toBe(0);
  expect(() => store.value.claim(second.token, nextMonth + 30_001)).toThrow(
    "invalid_grant",
  );
});

test("durable crash recovery releases holds, preserves settled usage and ownership", async () => {
  const { path, policy } = database(60);
  let store = new AccessStore(path, policy, "open");
  const session = store.enroll("apple-account", october);
  const settled = store.reserve(
    store.authenticate(session.token, october),
    10,
    october,
  );
  store.settle(store.claim(settled.token, october), 48_000, true);
  const interrupted = store.reserve(
    store.authenticate(session.token, october),
    30,
    october,
  );
  store.claim(interrupted.token, october);
  const snapshot = await store.backup();
  expect(snapshot.bytes).toBeGreaterThan(0);
  expect(snapshot.sha256).toHaveLength(64);
  expect(statSync(`${path}.backup`).mode & 0o777).toBe(0o640);
  validateSnapshot(`${path}.backup`);
  store.close();
  store = new AccessStore(path, policy, "open");
  try {
    expect(store.recoveredReservations).toBe(1);
    const same = store.enroll("apple-account", october);
    expect(same.subject).toBe(session.subject);
    expect(same.allowance.used_seconds).toBe(3);
    expect(same.allowance.reserved_seconds).toBe(0);
  } finally {
    store.close();
  }
});

function disposable(value: AccessStore) {
  return {
    value,
    [Symbol.dispose]() {
      value.close();
    },
  };
}

test("missing ledger and a competing owner fail without resetting allowance", () => {
  const { path, policy } = database(60);
  using store = disposable(new AccessStore(path, policy, "open"));
  const session = store.value.enroll("apple-account", october);
  store.value.reserve(
    store.value.authenticate(session.token, october),
    10,
    october,
  );
  expect(() => new AccessStore(path, policy, "initialize")).toThrow();
  expect(() => new AccessStore(path, policy, "open")).toThrow();
  expect(
    store.value.access(
      store.value.authenticate(session.token, october),
      october,
    ).reserved_seconds,
  ).toBe(10);
  const missing = `${path}.missing`;
  expect(() => new AccessStore(missing, policy, "open")).toThrow();
  expect(existsSync(missing)).toBe(false);
});

test("least recently renewed session is evicted while a claimed upload keeps its owner", () => {
  const { path, policy } = database(60);
  using store = disposable(new AccessStore(path, policy, "open"));
  const first = store.value.enroll("apple-account", october);
  const stale = store.value.enroll("apple-account", october + 1);
  const claimed = store.value.claim(
    store.value.reserve(
      store.value.authenticate(stale.token, october + 1),
      5,
      october + 1,
    ).token,
    october + 1,
  );
  const unclaimed = store.value.reserve(
    store.value.authenticate(stale.token, october + 1),
    5,
    october + 1,
  );
  for (let index = 2; index < 32; index++)
    store.value.enroll("apple-account", october + index);
  const renewed = store.value.renew(
    store.value.authenticate(first.token, october + 1000),
    october + 1000,
  );
  const latest = store.value.enroll("apple-account", october + 1001);
  expect(latest.subject).toBe(first.subject);
  expect(
    store.value.access(
      store.value.authenticate(renewed.token, october + 1001),
      october + 1001,
    ).used_seconds,
  ).toBe(0);
  expect(() =>
    store.value.access(
      store.value.authenticate(stale.token, october + 1001),
      october + 1001,
    ),
  ).toThrow("invalid_session");
  expect(() => store.value.claim(unclaimed.token, october + 1001)).toThrow(
    "invalid_grant",
  );
  store.value.settle(claimed, 16_000, true);
  expect(
    store.value.access(
      store.value.authenticate(latest.token, october + 1002),
      october + 1002,
    ),
  ).toMatchObject({
    used_seconds: 1,
    reserved_seconds: 0,
  });
});
