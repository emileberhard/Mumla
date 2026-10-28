import { Database } from "bun:sqlite";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { closeSync, openSync } from "node:fs";
import { chmod, rename, rm } from "node:fs/promises";
import {
  AccessError,
  OperatorIncident,
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
  subjectOverrides: Record<string, number>;
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
      validateDatabase(this.db);
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
    validateDatabase(this.db);
    this.checkCapacity();
  }

  private checkCapacity() {
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
    if (limit - pages + free < 256)
      throw new OperatorIncident("storage_capacity");
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
  }

  enroll(identityHash: string, now: number) {
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
    const reserved = this.db
      .query<{ samples: number }, [string, string]>(
        "SELECT COALESCE(SUM(limit_samples), 0) AS samples FROM grants WHERE subject = ? AND period = ?",
      )
      .get(subject, start)?.samples;
    if (reserved === undefined) throw new Error("Missing reservation total");
    return {
      limit_seconds:
        this.policy.subjectOverrides[subject] ?? this.policy.freeMonthlySeconds,
      used_seconds: used / sampleRate,
      reserved_seconds: reserved / sampleRate,
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
        if (allowance.used_seconds >= allowance.limit_seconds) {
          throw new AccessError(402, "allowance_exhausted");
        }
        const available = Math.floor(
          allowance.limit_seconds -
            allowance.used_seconds -
            allowance.reserved_seconds,
        );
        const active = this.db
          .query<{ count: number }, [string]>(
            "SELECT COUNT(*) AS count FROM grants WHERE subject = ?",
          )
          .get(session.subject)?.count;
        if (active === undefined) throw new Error("Missing grant count");
        if (available < 1 || active >= 2)
          throw new AccessError(409, "allowance_busy");
        const samples = Math.min(maximumSeconds, available) * sampleRate;
        const { token: grant, hash } = credential();
        const claimExpires = now + 30_000;
        const deadline = now + 180_000;
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

  settle(grant: Grant, samples: number, shouldCharge: boolean) {
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
        if (charged) {
          this.db
            .query(`INSERT INTO usage VALUES (?, ?, ?)
          ON CONFLICT (subject, period) DO UPDATE SET used_samples = used_samples + excluded.used_samples`)
            .run(grant.subject, grant.period, charged);
        }
      })
      .immediate();
  }

  revokeUnclaimed() {
    this.db.query("DELETE FROM grants WHERE claimed = 0").run();
  }
}

function validateDatabase(db: Database) {
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
}

export function validateSnapshot(path: string) {
  using db = new Database(path, { readonly: true, strict: true });
  validateDatabase(db);
}
