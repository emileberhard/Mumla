import { Database } from "bun:sqlite";
import { afterEach, expect, spyOn, test } from "bun:test";
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
  const policy = {
    freeMonthlySeconds: seconds,
    proMonthlySeconds: 108_000,
    sandboxProMonthlySeconds: 7200,
    subjectOverrides: {},
  };
  new AccessStore(path, policy, "initialize").close();
  return { path, policy };
}
const october = Date.parse("2026-10-31T23:59:50Z");

test("devices dictate at once from one allowance; a third attempt is busy, not exhausted", () => {
  const { path, policy } = database(2);
  using store = disposable(new AccessStore(path, policy, "open"));
  const phone = store.value.enroll("apple-account-a", october, "ios");
  const mac = store.value.enroll("apple-account-a", october, "ios");
  expect(phone.subject).toBe(mac.subject);
  const first = store.value.reserve(
    store.value.authenticate(phone.token, october),
    600,
    october,
  );
  expect(first.audio_limit_samples).toBe(32_000);
  const second = store.value.reserve(
    store.value.authenticate(mac.token, october),
    600,
    october,
  );
  expect(second.audio_limit_samples).toBe(32_000);
  expect(second.allowance).toMatchObject({
    in_flight_seconds: 4,
    reserved_seconds: 0,
  });
  expect(() =>
    store.value.reserve(
      store.value.authenticate(phone.token, october),
      1,
      october,
    ),
  ).toThrow("allowance_busy");
  const grant = store.value.claim(first.token, october);
  expect(() => store.value.claim(first.token, october)).toThrow(
    "invalid_grant",
  );
  store.value.settle(grant, sampleRate + 1, true, october, "ios");
  store.value.settle(
    store.value.claim(second.token, october),
    16_000,
    true,
    october,
    "ios",
  );
  expect(
    store.value.access(store.value.authenticate(mac.token, october), october)
      .used_seconds,
  ).toBe(3);
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
  const other = store.value.enroll("apple-account-b", october, "ios");
  expect(other.subject).not.toBe(phone.subject);
  expect(other.allowance.used_seconds).toBe(0);
});

test("rotation revokes the old session without invalidating an admitted upload", () => {
  const { path, policy } = database(60);
  using store = disposable(new AccessStore(path, policy, "open"));
  const original = store.value.enroll("apple-account", october, "ios");
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
  store.value.settle(
    store.value.claim(grant.token, october + 2),
    16_000,
    true,
    october + 2,
    "ios",
  );
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
  const fresh = store.value.enroll("apple-account", october + 5, "ios");
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
  const session = store.value.enroll("apple-account", october, "ios");
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
  store.value.settle(admitted, 16_000, true, nextMonth, "ios");
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
    ).in_flight_seconds,
  ).toBe(0);
  expect(() => store.value.claim(second.token, nextMonth + 30_001)).toThrow(
    "invalid_grant",
  );
});

test("durable crash recovery releases holds, preserves settled usage and ownership", async () => {
  const { path, policy } = database(60);
  let store = new AccessStore(path, policy, "open");
  const session = store.enroll("apple-account", october, "ios");
  const settled = store.reserve(
    store.authenticate(session.token, october),
    10,
    october,
  );
  store.settle(
    store.claim(settled.token, october),
    48_000,
    true,
    october,
    "ios",
  );
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
    const same = store.enroll("apple-account", october, "ios");
    expect(same.subject).toBe(session.subject);
    expect(same.allowance.used_seconds).toBe(3);
    expect(same.allowance.in_flight_seconds).toBe(0);
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
  const session = store.value.enroll("apple-account", october, "ios");
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
    ).in_flight_seconds,
  ).toBe(10);
  const missing = `${path}.missing`;
  expect(() => new AccessStore(missing, policy, "open")).toThrow();
  expect(existsSync(missing)).toBe(false);
});

test("least recently renewed session is evicted while a claimed upload keeps its owner", () => {
  const { path, policy } = database(60);
  using store = disposable(new AccessStore(path, policy, "open"));
  const first = store.value.enroll("apple-account", october, "ios");
  const stale = store.value.enroll("apple-account", october + 1, "ios");
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
    store.value.enroll("apple-account", october + index, "ios");
  const renewed = store.value.renew(
    store.value.authenticate(first.token, october + 1000),
    october + 1000,
  );
  const latest = store.value.enroll("apple-account", october + 1001, "ios");
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
  store.value.settle(claimed, 16_000, true, october + 1001, "ios");
  expect(
    store.value.access(
      store.value.authenticate(latest.token, october + 1002),
      october + 1002,
    ),
  ).toMatchObject({
    used_seconds: 1,
    in_flight_seconds: 0,
  });
});

test("activity keeps each account's daily sign-ins, charged dictations and free run-outs per platform for thirteen months", () => {
  const { path, policy } = database(20);
  let store = new AccessStore(path, policy, "open");
  const dictate = (
    token: string,
    samples: number,
    charge: boolean,
    at: number,
    platform: "ios" | "macos" | "unknown",
  ) =>
    store.settle(
      store.claim(
        store.reserve(store.authenticate(token, at), 10, at).token,
        at,
      ),
      samples,
      charge,
      at,
      platform,
    );
  const firstDay = Date.parse("2026-10-30T10:00:00Z");
  const phone = store.enroll("apple-account-a", firstDay, "ios");
  const mac = store.enroll("apple-account-a", october, "macos");
  const other = store.enroll("apple-account-b", firstDay, "unknown");
  dictate(phone.token, 16_000, true, firstDay, "ios");
  dictate(phone.token, 48_000, false, firstDay, "ios");
  dictate(mac.token, 8_000, true, october, "macos");
  dictate(other.token, 160_000, true, firstDay, "unknown");
  dictate(other.token, 160_000, true, october, "unknown");
  const rows = () => {
    store.close();
    const result = (() => {
      using db = new Database(path, { readonly: true, strict: true });
      return {
        starts: db
          .query(
            "SELECT enrolled, first_dictation FROM subject_starts ORDER BY enrolled, first_dictation",
          )
          .all(),
        days: db
          .query(
            "SELECT day, platform, enrollments, dictations, charged_samples, free_exhaustions FROM activity ORDER BY day, platform",
          )
          .all(),
      };
    })();
    store = new AccessStore(path, policy, "open");
    return result;
  };
  const day = (
    day: string,
    platform: string,
    enrollments: number,
    dictations: number,
    charged_samples: number,
    free_exhaustions: number,
  ) => ({
    day,
    platform,
    enrollments,
    dictations,
    charged_samples,
    free_exhaustions,
  });
  expect(rows()).toEqual({
    starts: [
      { enrolled: "2026-10-30", first_dictation: "2026-10-30" },
      { enrolled: "2026-10-30", first_dictation: "2026-10-30" },
    ],
    days: [
      day("2026-10-30", "ios", 1, 1, 16_000, 0),
      day("2026-10-30", "unknown", 1, 1, 160_000, 0),
      day("2026-10-31", "macos", 1, 1, 16_000, 0),
      day("2026-10-31", "unknown", 0, 1, 160_000, 1),
    ],
  });
  store.enroll("apple-account-c", Date.parse("2027-12-15T12:00:00Z"), "ios");
  const later = rows();
  expect(later.days).toEqual([day("2027-12-15", "ios", 1, 0, 0, 0)]);
  expect(later.starts).toContainEqual({
    enrolled: "2026-10-30",
    first_dictation: "2026-10-30",
  });
  store.close();
});

test("activity yields its oldest days to billing and reports it once a day while the ledger is over half full", () => {
  const { path, policy } = database(3600);
  const now = Date.parse("2026-11-20T12:00:00Z");
  let store = new AccessStore(path, policy, "open");
  const { token, subject } = store.enroll("apple-account-a", now, "ios");
  store.close();
  {
    using db = new Database(path, { strict: true });
    db.exec("CREATE TABLE filler (data BLOB) STRICT");
    db.query("INSERT INTO filler VALUES (zeroblob(?))").run(100 * 1024 * 1024);
    const insert = db.query(
      "INSERT INTO activity (subject, day, platform, dictations) VALUES (?, ?, 'macos', 1)",
    );
    for (let day = 0; day < 150; day++)
      insert.run(
        subject,
        new Date(Date.UTC(2026, 5, 1) + day * 86_400_000)
          .toISOString()
          .slice(0, 10),
      );
  }
  const reports: unknown[] = [];
  const consoleError = spyOn(console, "error").mockImplementation((line) =>
    reports.push(line),
  );
  try {
    store = new AccessStore(path, policy, "open");
    const session = store.authenticate(token, now);
    store.access(session, now);
    const days = () => {
      store.close();
      const result = (() => {
        using db = new Database(path, { readonly: true, strict: true });
        return db
          .query<{ day: string }, []>("SELECT day FROM activity ORDER BY day")
          .all()
          .map(({ day }) => day);
      })();
      store = new AccessStore(path, policy, "open");
      return result;
    };
    const remaining = days();
    expect(remaining).toHaveLength(51);
    expect(remaining[0]).toBe("2026-09-09");
    expect(remaining.at(-1)).toBe("2026-11-20");
    reports.length = 0;
    store.access(store.authenticate(token, now), now);
    store.access(store.authenticate(token, now), now);
    store.close();
    expect(
      reports.filter((line) => String(line).includes("analytics_capacity")),
    ).toHaveLength(1);
  } finally {
    consoleError.mockRestore();
  }
});
