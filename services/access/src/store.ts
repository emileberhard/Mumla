import { Database } from "bun:sqlite";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { closeSync, openSync } from "node:fs";
import { chmod, rename, rm } from "node:fs/promises";
import type { SignedTransaction } from "./appstore";
import {
  AccessError,
  OperatorIncident,
  type Platform,
  sampleRate,
  sessionLifetimeMs,
} from "./protocol";

export interface Session {
  readonly id: string;
  readonly subject: string;
  readonly token_hash: string;
}

export interface Grant {
  hash: string;
  subject: string;
  period: string;
  limit_samples: number;
  deadline: number;
}

interface Policy {
  freeMonthlySeconds: number;
  proMonthlySeconds: number;
  sandboxProMonthlySeconds: number;
  subjectOverrides: Record<string, number>;
}

const subscriptionSchema = `
  CREATE TABLE IF NOT EXISTS subscriptions (
    environment TEXT NOT NULL CHECK (environment IN ('Production', 'Sandbox')),
    original_transaction_id TEXT NOT NULL,
    owner TEXT,
    owner_transaction_id TEXT,
    owner_purchased INTEGER,
    transaction_id TEXT NOT NULL,
    purchased INTEGER NOT NULL,
    expires INTEGER NOT NULL,
    revoked INTEGER,
    signed INTEGER NOT NULL,
    PRIMARY KEY (environment, original_transaction_id)
  ) STRICT;
  CREATE INDEX IF NOT EXISTS subscriptions_owner ON subscriptions(owner);
`;

const activitySchema = `
  CREATE TABLE IF NOT EXISTS activity (
    subject TEXT NOT NULL REFERENCES subjects(id),
    day TEXT NOT NULL,
    platform TEXT NOT NULL CHECK (platform IN ('ios', 'macos', 'unknown')),
    enrollments INTEGER NOT NULL DEFAULT 0 CHECK (enrollments >= 0),
    dictations INTEGER NOT NULL DEFAULT 0 CHECK (dictations >= 0),
    charged_samples INTEGER NOT NULL DEFAULT 0 CHECK (charged_samples >= 0),
    free_exhaustions INTEGER NOT NULL DEFAULT 0 CHECK (free_exhaustions >= 0),
    PRIMARY KEY (subject, day, platform)
  ) STRICT;
  CREATE INDEX IF NOT EXISTS activity_day ON activity(day);
  CREATE TABLE IF NOT EXISTS subject_starts (
    subject TEXT PRIMARY KEY REFERENCES subjects(id),
    enrolled TEXT NOT NULL,
    first_dictation TEXT
  ) STRICT;
`;

const activityRetentionMonths = 13;

function utcDay(now: number) {
  return new Date(now).toISOString().slice(0, 10);
}

interface Subscription {
  owner: string | null;
  owner_transaction_id: string | null;
  owner_purchased: number | null;
  transaction_id: string;
  purchased: number;
  expires: number;
  revoked: number | null;
  signed: number;
}

function later(
  transaction: SignedTransaction,
  purchased: number,
  transactionId: string,
) {
  if (transaction.purchased !== purchased)
    return transaction.purchased > purchased;
  return BigInt(transaction.transactionId) > BigInt(transactionId);
}

function supersedes(transaction: SignedTransaction, stored: Subscription) {
  if (transaction.transactionId === stored.transaction_id)
    return transaction.signed > stored.signed;
  return later(transaction, stored.purchased, stored.transaction_id);
}

function namesOwner(
  transaction: SignedTransaction,
  stored: Subscription | null,
): transaction is SignedTransaction & { appAccountToken: string } {
  if (!transaction.appAccountToken) return false;
  if (stored?.owner_transaction_id == null || stored.owner_purchased == null)
    return true;
  return later(
    transaction,
    stored.owner_purchased,
    stored.owner_transaction_id,
  );
}

function digest(token: string) {
  return createHash("sha256").update(token).digest("hex");
}

function credential() {
  const token = randomBytes(32).toString("base64url");
  return { token, hash: digest(token) };
}

function month(now: number) {
  const date = new Date(now);
  return {
    start: Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), 1),
    end: Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + 1, 1),
  };
}

export class AccessStore {
  private readonly db: Database;
  private readonly path: string;
  private analyticsCapacityReported: string | undefined;
  readonly recoveredReservations: number;

  constructor(
    path: string,
    private readonly policy: Policy,
    mode: "initialize" | "open",
  ) {
    this.path = path;
    if (mode === "initialize") closeSync(openSync(path, "wx", 0o600));
    this.db = new Database(path, {
      strict: true,
      readwrite: true,
      create: false,
    });
    try {
      const version = this.db
        .query<{ user_version: number }, []>("PRAGMA user_version")
        .get()?.user_version;
      if (version !== (mode === "initialize" ? 0 : 1))
        throw new Error("Unsupported database version");
      this.db.exec(`
      PRAGMA locking_mode = EXCLUSIVE;
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = FULL;
      PRAGMA foreign_keys = ON;
      PRAGMA max_page_count = 49152;
      PRAGMA wal_autocheckpoint = 128;
      PRAGMA journal_size_limit = 16777216;
      BEGIN EXCLUSIVE;
      COMMIT;
    `);
      if (mode === "initialize")
        this.db.exec(`
      CREATE TABLE IF NOT EXISTS subjects (
        id TEXT PRIMARY KEY,
        identity_hash TEXT NOT NULL UNIQUE
      ) STRICT;
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        token_hash TEXT NOT NULL UNIQUE,
        subject TEXT NOT NULL REFERENCES subjects(id),
        expires INTEGER NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS usage (
        subject TEXT NOT NULL REFERENCES subjects(id),
        period TEXT NOT NULL,
        used_samples INTEGER NOT NULL CHECK (used_samples >= 0),
        PRIMARY KEY (subject, period)
      ) STRICT;
      CREATE TABLE IF NOT EXISTS grants (
        token_hash TEXT PRIMARY KEY,
        session_id TEXT NOT NULL REFERENCES sessions(id),
        subject TEXT NOT NULL REFERENCES subjects(id),
        period TEXT NOT NULL,
        limit_samples INTEGER NOT NULL CHECK (limit_samples > 0),
        claim_expires INTEGER NOT NULL,
        deadline INTEGER NOT NULL,
        claimed INTEGER NOT NULL CHECK (claimed IN (0, 1))
      ) STRICT;
      CREATE INDEX IF NOT EXISTS grants_subject ON grants(subject, period);
      CREATE INDEX IF NOT EXISTS sessions_subject ON sessions(subject);
      PRAGMA user_version = 1;
    `);
      this.db.exec(subscriptionSchema);
      this.db.exec(activitySchema);
      validateDatabase(this.db, "required");
      const recovery = this.db
        .query<{ count: number }, []>("SELECT COUNT(*) AS count FROM grants")
        .get()?.count;
      if (recovery === undefined) throw new Error("Missing recovery count");
      this.recoveredReservations = recovery;
      while (
        this.db
          .query(
            "DELETE FROM grants WHERE rowid IN (SELECT rowid FROM grants LIMIT 1000)",
          )
          .run().changes > 0
      ) {}
    } catch (error) {
      this.db.close(true);
      throw error;
    }
  }

  check() {
    validateDatabase(this.db, "required");
    this.checkCapacity();
  }

  private storage() {
    const pages = this.db
      .query<{ page_count: number }, []>("PRAGMA page_count")
      .get()?.page_count;
    const free = this.db
      .query<{ freelist_count: number }, []>("PRAGMA freelist_count")
      .get()?.freelist_count;
    const limit = this.db
      .query<{ max_page_count: number }, []>("PRAGMA max_page_count")
      .get()?.max_page_count;
    if (pages === undefined || free === undefined || limit === undefined)
      throw new Error("Missing storage capacity");
    return { used: pages - free, limit };
  }

  private checkCapacity() {
    const { used, limit } = this.storage();
    if (limit - used < 256) throw new OperatorIncident("storage_capacity");
  }

  async backup() {
    const temporary = `${this.path}.backup.tmp`;
    await rm(temporary, { force: true });
    this.db.query("VACUUM INTO ?").run(temporary);
    validateSnapshot(temporary);
    await chmod(temporary, 0o640);
    const file = Bun.file(temporary);
    const hash = new Bun.CryptoHasher("sha256");
    for await (const chunk of file.stream()) hash.update(chunk);
    const result = { sha256: hash.digest("hex"), bytes: file.size };
    await rename(temporary, `${this.path}.backup`);
    return result;
  }

  close() {
    this.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    this.db.close(true);
  }

  private prune(now: number) {
    this.db
      .query(
        "DELETE FROM grants WHERE rowid IN (SELECT rowid FROM grants WHERE claimed = 0 AND claim_expires <= ? LIMIT 1000)",
      )
      .run(now);
    this.db
      .query(`DELETE FROM sessions WHERE rowid IN (SELECT rowid FROM sessions WHERE expires <= ?
        AND id NOT IN (SELECT session_id FROM grants) LIMIT 1000)`)
      .run(now);
    const date = new Date(now);
    const cutoff = new Date(
      Date.UTC(date.getUTCFullYear(), date.getUTCMonth() - 2, 1),
    ).toISOString();
    this.db
      .query(
        "DELETE FROM usage WHERE rowid IN (SELECT rowid FROM usage WHERE period < ? AND period NOT IN (SELECT period FROM grants) LIMIT 1000)",
      )
      .run(cutoff);
    const activityCutoff = new Date(
      Date.UTC(
        date.getUTCFullYear(),
        date.getUTCMonth() - activityRetentionMonths,
        1,
      ),
    )
      .toISOString()
      .slice(0, 10);
    this.db
      .query(
        "DELETE FROM activity WHERE rowid IN (SELECT rowid FROM activity WHERE day < ? LIMIT 100)",
      )
      .run(activityCutoff);
    const { used, limit } = this.storage();
    if (used <= limit / 2) return;
    this.db
      .query(
        "DELETE FROM activity WHERE rowid IN (SELECT rowid FROM activity ORDER BY day LIMIT 100)",
      )
      .run();
    if (this.analyticsCapacityReported === utcDay(now)) return;
    this.analyticsCapacityReported = utcDay(now);
    console.error(
      JSON.stringify({
        event: "access_service_incident",
        code: "analytics_capacity",
      }),
    );
  }

  private recordActivity(
    subject: string,
    now: number,
    platform: Platform,
    counts: {
      enrollments?: number;
      dictations?: number;
      charged_samples?: number;
      free_exhaustions?: number;
    },
  ) {
    this.db
      .query(`INSERT INTO activity (subject, day, platform, enrollments, dictations, charged_samples, free_exhaustions)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (subject, day, platform) DO UPDATE SET
          enrollments = enrollments + excluded.enrollments,
          dictations = dictations + excluded.dictations,
          charged_samples = charged_samples + excluded.charged_samples,
          free_exhaustions = free_exhaustions + excluded.free_exhaustions`)
      .run(
        subject,
        utcDay(now),
        platform,
        counts.enrollments ?? 0,
        counts.dictations ?? 0,
        counts.charged_samples ?? 0,
        counts.free_exhaustions ?? 0,
      );
  }

  enroll(identityHash: string, now: number, platform: Platform) {
    return this.db
      .transaction(() => {
        this.checkCapacity();
        this.prune(now);
        let subject = this.db
          .query<{ id: string }, [string]>(
            "SELECT id FROM subjects WHERE identity_hash = ?",
          )
          .get(identityHash)?.id;
        if (!subject) {
          subject = randomUUID();
          this.db
            .query("INSERT INTO subjects VALUES (?, ?)")
            .run(subject, identityHash);
          this.db
            .query("INSERT INTO subject_starts VALUES (?, ?, NULL)")
            .run(subject, utcDay(now));
        }
        const count = this.db
          .query<{ count: number }, [string, number]>(
            "SELECT COUNT(*) AS count FROM sessions WHERE subject = ? AND expires > ?",
          )
          .get(subject, now)?.count;
        if (count === undefined) throw new Error("Missing session count");
        if (count >= 32) {
          const oldest = this.db
            .query<{ id: string }, [string, number]>(
              "SELECT id FROM sessions WHERE subject = ? AND expires > ? ORDER BY expires, rowid LIMIT 1",
            )
            .get(subject, now);
          if (!oldest) throw new Error("Missing oldest session");
          this.revokeSession(oldest.id, now);
        }
        const { token, hash } = credential();
        const expires = now + sessionLifetimeMs;
        this.db
          .query("INSERT INTO sessions VALUES (?, ?, ?, ?)")
          .run(randomUUID(), hash, subject, expires);
        this.recordActivity(subject, now, platform, { enrollments: 1 });
        return {
          token,
          expires_at: new Date(expires).toISOString(),
          subject,
          allowance: this.allowance(subject, now),
        };
      })
      .immediate();
  }

  authenticate(token: string, now: number): Session {
    const session = this.db
      .query<Session, [string, number]>(
        "SELECT id, subject, token_hash FROM sessions WHERE token_hash = ? AND expires > ?",
      )
      .get(digest(token), now);
    if (!session) throw new AccessError(401, "invalid_session");
    return session;
  }

  renew(session: Session, now: number) {
    return this.db
      .transaction(() => {
        const replacement = credential();
        const expires = now + sessionLifetimeMs;
        this.db
          .query("UPDATE sessions SET token_hash = ?, expires = ? WHERE id = ?")
          .run(replacement.hash, expires, session.id);
        return {
          token: replacement.token,
          expires_at: new Date(expires).toISOString(),
          subject: session.subject,
          allowance: this.allowance(session.subject, now),
        };
      })
      .immediate();
  }

  authenticateGrant(token: string, now: number) {
    const grant = this.db
      .query<{ subject: string }, [string, number]>(
        "SELECT subject FROM grants WHERE token_hash = ? AND claimed = 0 AND claim_expires > ?",
      )
      .get(digest(token), now);
    if (!grant) throw new AccessError(401, "invalid_grant");
    return grant.subject;
  }

  private revokeSession(id: string, now: number) {
    this.db
      .query("DELETE FROM grants WHERE session_id = ? AND claimed = 0")
      .run(id);
    this.db.query("UPDATE sessions SET expires = ? WHERE id = ?").run(now, id);
  }

  revoke(session: Session, now: number) {
    this.db.transaction(() => this.revokeSession(session.id, now)).immediate();
  }

  private allowance(subject: string, now: number) {
    const period = month(now);
    const start = new Date(period.start).toISOString();
    const used =
      this.db
        .query<{ used_samples: number }, [string, string]>(
          "SELECT used_samples FROM usage WHERE subject = ? AND period = ?",
        )
        .get(subject, start)?.used_samples ?? 0;
    const inFlight = this.db
      .query<{ samples: number }, [string, string]>(
        "SELECT COALESCE(SUM(limit_samples), 0) AS samples FROM grants WHERE subject = ? AND period = ?",
      )
      .get(subject, start)?.samples;
    if (inFlight === undefined) throw new Error("Missing in-flight total");
    const entitlement = this.db
      .query<{ production: number | null }, [string, number]>(
        "SELECT MAX(environment = 'Production') AS production FROM subscriptions WHERE owner = ? AND expires > ? AND revoked IS NULL",
      )
      .get(subject, now)?.production;
    if (entitlement === undefined) throw new Error("Missing plan");
    const base =
      this.policy.subjectOverrides[subject] ?? this.policy.freeMonthlySeconds;
    const pro =
      entitlement === null
        ? undefined
        : entitlement
          ? this.policy.proMonthlySeconds
          : this.policy.sandboxProMonthlySeconds;
    return {
      plan: pro === undefined ? "free" : "pro",
      limit_seconds: pro === undefined ? base : Math.max(base, pro),
      pro_limit_seconds: this.policy.proMonthlySeconds,
      used_seconds: used / sampleRate,
      in_flight_seconds: inFlight / sampleRate,
      reserved_seconds: 0,
      period_start: start,
      resets_at: new Date(period.end).toISOString(),
      observed_at: new Date(now).toISOString(),
    };
  }

  access(session: Session, now: number) {
    return this.db
      .transaction(() => {
        this.prune(now);
        return this.allowance(session.subject, now);
      })
      .immediate();
  }

  reserve(session: Session, maximumSeconds: number, now: number) {
    return this.db
      .transaction(() => {
        this.checkCapacity();
        this.prune(now);
        const allowance = this.allowance(session.subject, now);
        const remaining = Math.floor(
          allowance.limit_seconds - allowance.used_seconds,
        );
        if (remaining < 1) throw new AccessError(402, "allowance_exhausted");
        const active = this.db
          .query<{ count: number }, [string]>(
            "SELECT COUNT(*) AS count FROM grants WHERE subject = ?",
          )
          .get(session.subject)?.count;
        if (active === undefined) throw new Error("Missing grant count");
        if (active >= 2) throw new AccessError(409, "allowance_busy");
        const samples = Math.min(maximumSeconds, remaining) * sampleRate;
        const { token: grant, hash } = credential();
        const claimExpires = now + 30_000;
        const deadline = now + (samples / sampleRate + 70) * 1000;
        const inserted = this.db
          .query(`INSERT INTO grants
            SELECT ?, ?, ?, ?, ?, ?, ?, 0 FROM sessions
            WHERE id = ? AND token_hash = ? AND expires > ?
            RETURNING token_hash`)
          .get(
            hash,
            session.id,
            session.subject,
            allowance.period_start,
            samples,
            claimExpires,
            deadline,
            session.id,
            session.token_hash,
            now,
          );
        if (!inserted) throw new AccessError(401, "invalid_session");
        return {
          token: grant,
          claim_expires_at: new Date(claimExpires).toISOString(),
          request_deadline: new Date(deadline).toISOString(),
          audio_limit_samples: samples,
          allowance: this.allowance(session.subject, now),
        };
      })
      .immediate();
  }

  claim(token: string, now: number): Grant {
    const grant = this.db
      .query<Grant, [string, number]>(`
      UPDATE grants SET claimed = 1
      WHERE token_hash = ? AND claimed = 0 AND claim_expires > ?
      RETURNING token_hash AS hash, subject, period, limit_samples, deadline
    `)
      .get(digest(token), now);
    if (!grant) throw new AccessError(401, "invalid_grant");
    return grant;
  }

  settle(
    grant: Grant,
    samples: number,
    shouldCharge: boolean,
    now: number,
    platform: Platform,
  ) {
    if (
      !Number.isSafeInteger(samples) ||
      samples < 0 ||
      samples > grant.limit_samples
    ) {
      throw new Error("Invalid measured samples");
    }
    const charged = shouldCharge
      ? Math.max(sampleRate, Math.ceil(samples / sampleRate) * sampleRate)
      : 0;
    this.db
      .transaction(() => {
        const deleted = this.db
          .query(
            "DELETE FROM grants WHERE token_hash = ? AND claimed = 1 RETURNING token_hash",
          )
          .get(grant.hash);
        if (!deleted) throw new Error("Reservation already settled");
        if (!charged) return;
        const before = this.allowance(grant.subject, now);
        const limit = before.limit_seconds * sampleRate;
        const used = before.used_seconds * sampleRate;
        const ranOutOfFree =
          before.plan === "free" &&
          before.period_start === grant.period &&
          used < limit &&
          used + charged >= limit;
        this.db
          .query(`INSERT INTO usage VALUES (?, ?, ?)
          ON CONFLICT (subject, period) DO UPDATE SET used_samples = used_samples + excluded.used_samples`)
          .run(grant.subject, grant.period, charged);
        this.recordActivity(grant.subject, now, platform, {
          dictations: 1,
          charged_samples: charged,
          free_exhaustions: ranOutOfFree ? 1 : 0,
        });
        this.db
          .query(
            "UPDATE subject_starts SET first_dictation = ? WHERE subject = ? AND first_dictation IS NULL",
          )
          .run(utcDay(now), grant.subject);
      })
      .immediate();
  }

  private applyPurchase(
    transaction: SignedTransaction,
    claimant: string | null,
  ) {
    const stored = this.db
      .query<Subscription, [string, string]>(
        "SELECT owner, owner_transaction_id, owner_purchased, transaction_id, purchased, expires, revoked, signed FROM subscriptions WHERE environment = ? AND original_transaction_id = ?",
      )
      .get(transaction.environment, transaction.originalTransactionId);
    const ownership = namesOwner(transaction, stored)
      ? [
          transaction.appAccountToken,
          transaction.transactionId,
          transaction.purchased,
        ]
      : stored?.owner
        ? [stored.owner, stored.owner_transaction_id, stored.owner_purchased]
        : [claimant, null, null];
    const state =
      !stored || supersedes(transaction, stored)
        ? [
            transaction.transactionId,
            transaction.purchased,
            transaction.expires,
            transaction.revoked,
            transaction.signed,
          ]
        : [
            stored.transaction_id,
            stored.purchased,
            stored.expires,
            stored.revoked,
            stored.signed,
          ];
    this.db
      .query(
        "INSERT OR REPLACE INTO subscriptions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      )
      .run(
        transaction.environment,
        transaction.originalTransactionId,
        ...ownership,
        ...state,
      );
    return ownership[0];
  }

  purchase(session: Session, transaction: SignedTransaction, now: number) {
    const allowance = this.db
      .transaction(() => {
        this.checkCapacity();
        this.prune(now);
        if (
          !this.db
            .query(
              "SELECT 1 FROM sessions WHERE id = ? AND token_hash = ? AND expires > ?",
            )
            .get(session.id, session.token_hash, now)
        )
          throw new AccessError(401, "invalid_session");
        return this.applyPurchase(transaction, session.subject) ===
          session.subject
          ? this.allowance(session.subject, now)
          : null;
      })
      .immediate();
    if (!allowance) throw new AccessError(409, "purchase_owned_elsewhere");
    return allowance;
  }

  notify(transaction: SignedTransaction, now: number) {
    this.db
      .transaction(() => {
        this.checkCapacity();
        this.prune(now);
        this.applyPurchase(transaction, null);
      })
      .immediate();
  }

  revokeUnclaimed() {
    this.db.query("DELETE FROM grants WHERE claimed = 0").run();
  }
}

function validateDatabase(db: Database, added: "required" | "optional") {
  const integrity = db
    .query<{ quick_check: string }, []>("PRAGMA quick_check")
    .all();
  if (integrity.length !== 1 || integrity[0]?.quick_check !== "ok")
    throw new Error("Database integrity check failed");
  if (
    db.query<{ user_version: number }, []>("PRAGMA user_version").get()
      ?.user_version !== 1
  )
    throw new Error("Unsupported database version");
  db.query("SELECT id, identity_hash FROM subjects LIMIT 0").all();
  db.query(
    "SELECT id, token_hash, subject, expires FROM sessions LIMIT 0",
  ).all();
  db.query("SELECT subject, period, used_samples FROM usage LIMIT 0").all();
  db.query(
    "SELECT token_hash, session_id, subject, period, limit_samples, claim_expires, deadline, claimed FROM grants LIMIT 0",
  ).all();
  for (const [table, columns] of [
    [
      "subscriptions",
      "environment, original_transaction_id, owner, owner_transaction_id, owner_purchased, transaction_id, purchased, expires, revoked, signed",
    ],
    [
      "activity",
      "subject, day, platform, enrollments, dictations, charged_samples, free_exhaustions",
    ],
    ["subject_starts", "subject, enrolled, first_dictation"],
  ]) {
    const present = db
      .query<{ count: number }, [string]>(
        "SELECT COUNT(*) AS count FROM sqlite_schema WHERE type = 'table' AND name = ?",
      )
      .get(table as string)?.count;
    if (present === 0 && added === "optional") continue;
    db.query(`SELECT ${columns} FROM ${table} LIMIT 0`).all();
  }
}

export function validateSnapshot(path: string) {
  using db = new Database(path, { readonly: true, strict: true });
  validateDatabase(db, "optional");
}
