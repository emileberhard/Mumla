import { timingSafeEqual } from "node:crypto";
import { isIP } from "node:net";
import type { IdentityVerifier } from "./cloudkit";
import type { AccessConfig } from "./config";
import {
  AccessError,
  boundedBytes,
  exactKeys,
  integer,
  jsonBody,
  maximumAudioSeconds,
  OperatorIncident,
  parseJSON,
  RequestIncident,
  record,
  transcriptionPath,
} from "./protocol";
import { checkRouter } from "./readiness";
import type { AccessStore, Session } from "./store";
import { TranscriptionUpload } from "./transcription";

export interface ReleaseIdentity {
  version: string;
  commit: string;
}

function json(value: unknown, status = 200) {
  return Response.json(value, {
    status,
    headers: { "Cache-Control": "no-store" },
  });
}

function bearer(request: Request) {
  const match = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(
    request.headers.get("authorization") ?? "",
  );
  if (!match?.[1]) throw new AccessError(401, "invalid_credential");
  return match[1];
}

function originLimits(address: string | null): [string, number][] {
  if (!address || address.includes("%") || !isIP(address))
    throw new RequestIncident("client_ip_unavailable");
  if (isIP(address) === 4) return [[address, 10]];
  const canonical = new URL(`http://[${address}]`).hostname.slice(1, -1);
  const [left, right] = canonical.split("::");
  const first = (left ?? "").split(":").filter(Boolean);
  const last = (right ?? "").split(":").filter(Boolean);
  const words =
    right === undefined
      ? first
      : [
          ...first,
          ...Array<string>(8 - first.length - last.length).fill("0"),
          ...last,
        ];
  if (
    words.slice(0, 5).every((word) => Number.parseInt(word, 16) === 0) &&
    words[5] === "ffff"
  ) {
    const high = Number.parseInt(words[6] ?? "", 16);
    const low = Number.parseInt(words[7] ?? "", 16);
    return [[[high >>> 8, high & 255, low >>> 8, low & 255].join("."), 10]];
  }
  return [
    [`${words.slice(0, 4).join(":")}::/64`, 10],
    [`${words.slice(0, 3).join(":")}::/48`, 100],
  ];
}

function connectionFailure(error: unknown) {
  const value =
    error instanceof Error
      ? (error as Error & { code?: string; cause?: { code?: string } })
      : undefined;
  return [
    "ECONNREFUSED",
    "ECONNRESET",
    "EPIPE",
    "ENETUNREACH",
    "EHOSTUNREACH",
    "ENOTFOUND",
    "EAI_AGAIN",
    "ConnectionRefused",
    "ConnectionClosed",
  ].includes(value?.code ?? value?.cause?.code ?? "");
}

export class AccessService {
  private admissionOpen = false;
  private healthy = false;
  private failed = false;
  private backingUp = false;
  private requests = 0;
  private readonly enrollments = new Set<AbortController>();
  private fatalReported = false;
  private readonly pendingUploads = new Map<string, AbortController>();
  private readonly uploads = new Set<string>();
  private readonly subjectRequests = new Map<string, { count: number }>();
  private readonly requestIncidents = new Map<string, number>();
  private readonly origins = new Map<
    string,
    { count: number; resets: number }
  >();

  constructor(
    private readonly config: AccessConfig,
    private readonly identity: IdentityVerifier,
    private readonly store: AccessStore,
    private readonly release: ReleaseIdentity,
    private readonly onFatal: () => void,
  ) {}

  async check() {
    this.store.check();
    await Promise.all([checkRouter(this.config), this.identity.check()]);
    this.healthy = true;
  }

  private active() {
    return Number(this.backingUp) + this.uploads.size;
  }

  private rateLimit(limits: [string, number][], now: number) {
    for (const [key, value] of this.origins)
      if (value.resets <= now) this.origins.delete(key);
    const entries = limits.map(([key, limit]) => {
      const entry = this.origins.get(key) ?? { count: 0, resets: now + 60_000 };
      this.origins.delete(key);
      this.origins.set(key, entry);
      return { entry, limit };
    });
    for (const key of this.origins.keys()) {
      if (this.origins.size <= 10_000) break;
      this.origins.delete(key);
    }
    if (entries.some(({ entry, limit }) => entry.count >= limit))
      throw new AccessError(429, "enrollment_rate_limited");
    for (const { entry } of entries) entry.count++;
  }

  private requestIncident(error: RequestIncident) {
    const now = Date.now();
    if ((this.requestIncidents.get(error.incidentCode) ?? 0) > now) return;
    this.requestIncidents.set(error.incidentCode, now + 60_000);
    console.error(
      JSON.stringify({
        event: "access_service_incident",
        code: error.incidentCode,
      }),
    );
  }

  private incident(error: unknown) {
    if (this.failed) return;
    this.failed = true;
    this.healthy = false;
    this.closeAdmission();
    const candidate = error as { code?: unknown; name?: unknown } | null;
    const sqliteCode =
      typeof candidate?.code === "string" &&
      /^SQLITE_[A-Z_]+$/.test(candidate.code)
        ? candidate.code
        : undefined;
    const errorClass =
      typeof candidate?.name === "string" &&
      /^[A-Za-z]{1,64}$/.test(candidate.name)
        ? candidate.name
        : typeof error;
    console.error(
      JSON.stringify({
        event: "access_service_incident",
        code:
          error instanceof OperatorIncident ? error.code : "unexpected_failure",
        error_class: errorClass,
        sqlite_code: sqliteCode,
      }),
    );
  }

  private finishFailure() {
    if (
      this.failed &&
      !this.fatalReported &&
      this.requests === 0 &&
      !this.backingUp
    ) {
      this.fatalReported = true;
      queueMicrotask(this.onFatal);
    }
  }

  private operator(request: Request) {
    const supplied = Buffer.from(request.headers.get("authorization") ?? "");
    const expected = Buffer.from(`Bearer ${this.config.operatorToken}`);
    if (
      supplied.length !== expected.length ||
      !timingSafeEqual(supplied, expected)
    )
      throw new AccessError(404, "not_found");
  }

  private async control(request: Request, path: string) {
    this.operator(request);
    if (path === "/internal/status" && request.method === "GET")
      return json({
        ...this.release,
        ready: this.healthy,
        admission_open: this.admissionOpen,
        active: this.active(),
      });
    if (path === "/internal/backup" && request.method === "POST") {
      if (this.backingUp) throw new AccessError(409, "backup_busy");
      this.backingUp = true;
      try {
        return json(await this.store.backup());
      } finally {
        this.backingUp = false;
        this.finishFailure();
      }
    }
    if (path === "/internal/fence" && request.method === "POST") {
      if (!this.fenceForShutdown())
        return json(
          { admission_open: this.admissionOpen, active: this.active() },
          409,
        );
      return json({ admission_open: false, active: 0 });
    }
    if (path === "/internal/reopen" && request.method === "POST") {
      if (!this.healthy || this.failed)
        throw new AccessError(503, "service_unavailable");
      this.admissionOpen = true;
      return json({ admission_open: true, active: this.active() });
    }
    throw new AccessError(404, "not_found");
  }

  async handle(request: Request, address: string | null): Promise<Response> {
    let counted = false;
    let subject: string | undefined;
    let subjectCounter: { count: number } | undefined;
    try {
      const url = new URL(request.url);
      if (request.headers.has("upgrade"))
        throw new AccessError(400, "unsupported_transport");
      if (
        url.pathname === "/healthz" &&
        request.method === "GET" &&
        !url.search
      )
        return json(
          { ...this.release, ready: this.healthy && this.admissionOpen },
          this.healthy && this.admissionOpen ? 200 : 503,
        );
      if (url.pathname.startsWith("/internal/") && !url.search)
        return await this.control(request, url.pathname);
      if (!this.admissionOpen || !this.healthy)
        throw new AccessError(503, "service_unavailable");
      const now = Date.now();
      if (url.pathname === "/v1/sessions" && request.method === "POST") {
        if (url.search) throw new AccessError(400, "invalid_request");
        return await this.enroll(request, address, now);
      }
      let session: Session | undefined;
      if (url.pathname === transcriptionPath && request.method === "POST") {
        subject = this.store.authenticateGrant(bearer(request), now);
      } else if (
        (url.pathname === "/v1/dictations" && request.method === "POST") ||
        (url.pathname === "/v1/access" && request.method === "GET") ||
        (url.pathname === "/v1/session/renew" && request.method === "POST") ||
        (url.pathname === "/v1/session" && request.method === "DELETE")
      ) {
        session = this.store.authenticate(bearer(request), now);
        subject = session.subject;
      }
      if (subject) {
        subjectCounter = this.subjectRequests.get(subject) ?? { count: 0 };
        if (subjectCounter.count >= 4)
          throw new AccessError(503, "service_busy");
      }
      if (this.requests >= 64) throw new AccessError(503, "service_busy");
      this.requests++;
      if (subject && subjectCounter) {
        subjectCounter.count++;
        this.subjectRequests.set(subject, subjectCounter);
      }
      counted = true;
      if (url.pathname === transcriptionPath && request.method === "POST") {
        const query = [...url.searchParams];
        if (
          query.length !== 1 ||
          query[0]?.[0] !== "api-version" ||
          query[0]?.[1] !== "2025-10-15"
        )
          throw new AccessError(400, "unsupported_transcription");
        return await this.transcribe(request, now);
      }
      if (url.search) throw new AccessError(400, "invalid_request");
      if (url.pathname === "/v1/access" && request.method === "GET" && session)
        return json({ allowance: this.store.access(session, now) });
      if (
        url.pathname === "/v1/session/renew" &&
        request.method === "POST" &&
        session
      )
        return json(this.store.renew(session, now));
      if (
        url.pathname === "/v1/session" &&
        request.method === "DELETE" &&
        session
      ) {
        this.store.revoke(session, now);
        return new Response(null, {
          status: 204,
          headers: { "Cache-Control": "no-store" },
        });
      }
      if (
        url.pathname === "/v1/dictations" &&
        request.method === "POST" &&
        session
      ) {
        const body = await jsonBody(
          request,
          1024,
          AbortSignal.any([request.signal, AbortSignal.timeout(2000)]),
        );
        exactKeys(body, ["maximum_audio_seconds"]);
        const maximum = integer(
          body.maximum_audio_seconds,
          1,
          maximumAudioSeconds,
        );
        if (!this.admissionOpen || !this.healthy)
          throw new AccessError(503, "service_unavailable");
        return json(this.store.reserve(session, maximum, Date.now()), 201);
      }
      throw new AccessError(404, "not_found");
    } catch (error) {
      void request.body?.cancel().catch(() => {});
      if (error instanceof RequestIncident) this.requestIncident(error);
      if (error instanceof AccessError)
        return json({ error: { code: error.code } }, error.status);
      this.incident(error);
      return json({ error: { code: "service_unavailable" } }, 503);
    } finally {
      if (counted) {
        this.requests--;
        if (subject && subjectCounter) {
          subjectCounter.count--;
          if (subjectCounter.count === 0) this.subjectRequests.delete(subject);
        }
      }
      this.finishFailure();
    }
  }

  private async enroll(request: Request, address: string | null, now: number) {
    const origin = originLimits(address);
    if (this.enrollments.size >= 8) throw new AccessError(503, "service_busy");
    this.rateLimit(origin, now);
    const abort = new AbortController();
    const signal = AbortSignal.any([request.signal, abort.signal]);
    this.enrollments.add(abort);
    try {
      const body = await jsonBody(
        request,
        16 * 1024,
        AbortSignal.any([signal, AbortSignal.timeout(2000)]),
      );
      exactKeys(body, ["web_auth_token"]);
      if (
        typeof body.web_auth_token !== "string" ||
        !body.web_auth_token ||
        body.web_auth_token.length > 12 * 1024
      )
        throw new AccessError(400, "invalid_request");
      const identity = await this.identity.verify(body.web_auth_token, signal);
      if (!this.admissionOpen || !this.healthy)
        throw new AccessError(503, "service_unavailable");
      return json(this.store.enroll(identity, Date.now()), 201);
    } catch (error) {
      if (error instanceof OperatorIncident) throw error;
      if (abort.signal.aborted)
        throw new AccessError(503, "service_unavailable");
      throw error;
    } finally {
      this.enrollments.delete(abort);
    }
  }

  private async transcribe(request: Request, now: number) {
    const grant = this.store.claim(bearer(request), now);
    const abort = new AbortController();
    this.pendingUploads.set(grant.hash, abort);
    const deadline = AbortSignal.timeout(Math.max(1, grant.deadline - now));
    const signal = AbortSignal.any([request.signal, abort.signal, deadline]);
    let upload: TranscriptionUpload | undefined;
    let charge = false;
    let upstreamRefused = false;
    let inputRejected = false;
    let refusedDispatch = false;
    try {
      upload = new TranscriptionUpload(request, grant.limit_samples, signal);
      const prepared = await upload.prepare(() => {
        if (abort.signal.aborted || !this.admissionOpen || !this.healthy) {
          refusedDispatch = true;
          throw new AccessError(503, "service_unavailable");
        }
        this.pendingUploads.delete(grant.hash);
        this.uploads.add(grant.hash);
      });
      const uploadSignal = AbortSignal.any([signal, prepared.signal]);
      const response = await fetch(
        `${this.config.routerOrigin}${transcriptionPath}?api-version=2025-10-15`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${this.config.routerKey}`,
            "Content-Type": prepared.contentType,
          },
          body: prepared.body,
          signal: uploadSignal,
          redirect: "error",
        },
      );
      if (!response.ok) {
        upstreamRefused = true;
        await response.body?.cancel();
        if ([401, 403].includes(response.status))
          throw new OperatorIncident("router_credentials_rejected");
        inputRejected = [400, 422].includes(response.status);
        throw new AccessError(502, "transcription_failed");
      }
      let result: Record<string, unknown>;
      try {
        const bytes = await boundedBytes(
          response.body,
          1024 * 1024,
          uploadSignal,
        );
        result = record(
          parseJSON(new TextDecoder("utf-8", { fatal: true }).decode(bytes)),
        );
        if (
          !Array.isArray(result.combinedPhrases) ||
          result.combinedPhrases.some(
            (phrase) => typeof record(phrase).text !== "string",
          ) ||
          !upload.isComplete
        )
          throw new Error("Invalid provider result");
      } catch (error) {
        if (request.signal.aborted) throw error;
        upstreamRefused = true;
        throw new AccessError(502, "transcription_failed");
      }
      charge = true;
      return json({
        combinedPhrases: (result.combinedPhrases as unknown[]).map(
          (phrase) => ({ text: record(phrase).text }),
        ),
      });
    } catch (error) {
      const clientFailure =
        request.signal.aborted ||
        upload?.failure ||
        (error instanceof AccessError && error.status < 500) ||
        (deadline.aborted && upload?.interruptedWhileWaitingForClient);
      charge =
        inputRejected ||
        (!upstreamRefused &&
          !refusedDispatch &&
          !connectionFailure(error) &&
          Boolean(clientFailure) &&
          (Boolean(upload?.bodyHandedOff) || !abort.signal.aborted));
      if (error instanceof OperatorIncident) throw error;
      if (abort.signal.aborted && !upload?.bodyHandedOff)
        throw new AccessError(503, "service_unavailable");
      if (upload?.failure && !upstreamRefused) throw upload.failure;
      if (error instanceof AccessError) throw error;
      throw new AccessError(502, "transcription_failed");
    } finally {
      abort.abort();
      try {
        await upload?.close();
        this.store.settle(
          grant,
          inputRejected ? 0 : (upload?.samples ?? 0),
          charge,
        );
      } finally {
        this.pendingUploads.delete(grant.hash);
        this.uploads.delete(grant.hash);
      }
    }
  }

  fenceForShutdown() {
    if (this.active() !== 0) return false;
    this.store.revokeUnclaimed();
    this.closeAdmission();
    return true;
  }

  private closeAdmission() {
    this.admissionOpen = false;
    for (const enrollment of this.enrollments) enrollment.abort();
    for (const upload of this.pendingUploads.values()) upload.abort();
  }
}
