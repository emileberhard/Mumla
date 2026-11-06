import { randomUUID, timingSafeEqual } from "node:crypto";
import { isIP } from "node:net";
import type { ServerWebSocket } from "bun";
import type { AppStoreVerifier } from "./appstore";
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
  type Platform,
  parseJSON,
  platform,
  RequestIncident,
  record,
  sampleRate,
  streamPath,
  transcriptionPath,
} from "./protocol";
import { checkRouter } from "./readiness";
import type { AccessStore, Grant, Session } from "./store";
import {
  KeptAudioBudget,
  keptAudioBudgetBytes,
  StreamUpload,
  type VoicePhrase,
  voicePhrases,
  wavHeader,
} from "./stream";
import { TranscriptionUpload } from "./transcription";

export interface ReleaseIdentity {
  version: string;
  commit: string;
}

interface AudioInput {
  readonly samples: number;
  readonly failure: AccessError | undefined;
  readonly bodyHandedOff: boolean;
  readonly isComplete: boolean;
  readonly interruptedWhileWaitingForClient: boolean;
  readonly audioEndedAt: number | undefined;
  readonly diarized: boolean;
  prepare(onDispatch: () => void): Promise<{
    signal: AbortSignal;
    contentType: string;
    body: ReadableStream<Uint8Array>;
  }>;
  close(): Promise<void>;
}

class Phases {
  private readonly origin = performance.now();
  readonly marks: Record<string, number> = {};

  mark(name: string, at = performance.now()) {
    this.marks[`${name}_ms`] ??= Math.round(at - this.origin);
  }
}

function outcome(error: unknown) {
  if (error instanceof AccessError)
    return { status: error.status, code: error.code };
  if (error instanceof OperatorIncident)
    return { status: 503, code: error.code };
  return { status: 503, code: "unexpected_failure" };
}

interface StreamState {
  grant: Grant;
  platform: Platform;
  claimedAt: number;
  client: AbortController;
  release: () => void;
  upload?: StreamUpload;
}

interface Transcript {
  texts: string[];
  phrases: VoicePhrase[] | undefined;
}

const voicesWaitMs = 5000;
const voicesTimeoutMs = 30_000;
const diarizedResultBytes = 4 * 1024 * 1024;

interface Upgrader {
  upgrade(request: Request, options: { data: StreamState }): boolean;
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
  private readonly notifications = new Set<AbortController>();
  private readonly purchaseChecks = new Set<AbortController>();
  private fatalReported = false;
  private readonly pendingUploads = new Map<string, AbortController>();
  private readonly uploads = new Set<string>();
  private voiceStreams = 0;
  private readonly keptAudio = new KeptAudioBudget(keptAudioBudgetBytes);
  private readonly subjectRequests = new Map<string, { count: number }>();
  private readonly requestIncidents = new Map<string, number>();
  private readonly origins = new Map<
    string,
    { count: number; resets: number }
  >();

  constructor(
    private readonly config: AccessConfig,
    private readonly identity: IdentityVerifier,
    private readonly purchases: AppStoreVerifier,
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
    return Number(this.backingUp) + this.uploads.size + this.voiceStreams;
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

  readonly websocket = {
    data: {} as StreamState,
    maxPayloadLength: 256 * 1024,
    idleTimeout: 60,
    open: (socket: ServerWebSocket<StreamState>) => {
      void this.stream(socket);
    },
    message: (
      socket: ServerWebSocket<StreamState>,
      message: string | Buffer,
    ) => {
      socket.data.upload?.receive(message);
    },
    close: (socket: ServerWebSocket<StreamState>) => {
      socket.data.client.abort();
    },
  };

  handle(request: Request, address: string | null): Promise<Response>;
  handle(
    request: Request,
    address: string | null,
    server: Upgrader,
  ): Promise<Response | undefined>;
  async handle(
    request: Request,
    address: string | null,
    server?: Upgrader,
  ): Promise<Response | undefined> {
    let counted = false;
    let subject: string | undefined;
    let subjectCounter: { count: number } | undefined;
    try {
      const url = new URL(request.url);
      const streaming =
        url.pathname === streamPath &&
        request.method === "GET" &&
        !url.search &&
        request.headers.get("upgrade")?.toLowerCase() === "websocket" &&
        server !== undefined;
      if (request.headers.has("upgrade") !== streaming)
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
      if (
        url.pathname === "/v1/app-store/notifications" &&
        request.method === "POST"
      ) {
        if (url.search) throw new AccessError(400, "invalid_request");
        return await this.notification(request);
      }
      let session: Session | undefined;
      if (
        streaming ||
        (url.pathname === transcriptionPath && request.method === "POST")
      ) {
        subject = this.store.authenticateGrant(bearer(request), now);
      } else if (
        (url.pathname === "/v1/dictations" && request.method === "POST") ||
        (url.pathname === "/v1/purchases" && request.method === "POST") ||
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
      if (streaming && server) {
        const grant = this.store.claim(bearer(request), now);
        const owner = subject;
        const counter = subjectCounter;
        let released = false;
        const state: StreamState = {
          grant,
          platform: platform(request),
          claimedAt: now,
          client: new AbortController(),
          release: () => {
            if (released) return;
            released = true;
            this.freeSlot(owner, counter);
          },
        };
        if (!server.upgrade(request, { data: state })) {
          this.store.settle(grant, 0, false, Date.now(), state.platform);
          throw new AccessError(400, "unsupported_transport");
        }
        counted = false;
        return undefined;
      }
      if (url.pathname === transcriptionPath && request.method === "POST") {
        const query = [...url.searchParams];
        if (
          query.length !== 1 ||
          query[0]?.[0] !== "api-version" ||
          query[0]?.[1] !== "2025-10-15"
        )
          throw new AccessError(400, "unsupported_transcription");
        const grant = this.store.claim(bearer(request), now);
        const transcript = await this.transcribe(
          grant,
          request.signal,
          (signal) =>
            new TranscriptionUpload(request, grant.limit_samples, signal),
          now,
          "upload",
          randomUUID(),
          platform(request),
        );
        return json({
          combinedPhrases: transcript.texts.map((text) => ({ text })),
        });
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
      if (
        url.pathname === "/v1/purchases" &&
        request.method === "POST" &&
        session
      )
        return await this.purchase(request, session);
      throw new AccessError(404, "not_found");
    } catch (error) {
      void request.body?.cancel().catch(() => {});
      if (error instanceof RequestIncident) this.requestIncident(error);
      if (error instanceof AccessError)
        return json({ error: { code: error.code } }, error.status);
      this.incident(error);
      return json({ error: { code: "service_unavailable" } }, 503);
    } finally {
      if (counted) this.freeSlot(subject, subjectCounter);
      this.finishFailure();
    }
  }

  private freeSlot(
    subject: string | undefined,
    subjectCounter: { count: number } | undefined,
  ) {
    this.requests--;
    if (subject && subjectCounter) {
      subjectCounter.count--;
      if (subjectCounter.count === 0) this.subjectRequests.delete(subject);
    }
  }

  private async stream(socket: ServerWebSocket<StreamState>) {
    const state = socket.data;
    const id = randomUUID();
    const voicesAbort = new AbortController();
    const voicesSignal = AbortSignal.any([
      state.client.signal,
      voicesAbort.signal,
    ]);
    let voices: Promise<Record<string, unknown>> | undefined;
    let waitingForVoices = false;
    try {
      const transcript = await this.transcribe(
        state.grant,
        state.client.signal,
        (signal) => {
          const upload = new StreamUpload(
            socket,
            state.grant.limit_samples,
            signal,
            this.keptAudio,
          );
          state.upload = upload;
          void upload.voicesRequest.then(() => {
            voices = this.voices(upload, voicesSignal, id);
          });
          return upload;
        },
        state.claimedAt,
        "stream",
        id,
        state.platform,
      );
      const upload = state.upload;
      const text = transcript.texts.join("\n");
      if (upload?.diarized) {
        socket.send(
          JSON.stringify({
            type: "voices",
            text,
            phrases: transcript.phrases,
            id,
          }),
        );
        return;
      }
      socket.send(JSON.stringify({ type: "result", text, id }));
      if (upload?.speakers !== "onRequest") return;
      this.voiceStreams++;
      waitingForVoices = true;
      const waited = AbortSignal.any([
        voicesSignal,
        AbortSignal.timeout(voicesWaitMs),
      ]);
      const requested = await Promise.race([
        upload.voicesRequest.then(() => true),
        new Promise<boolean>((resolve) => {
          if (waited.aborted) resolve(false);
          waited.addEventListener("abort", () => resolve(false), {
            once: true,
          });
        }),
      ]);
      if (requested && voices)
        socket.send(JSON.stringify({ ...(await voices), id }));
    } catch (error) {
      if (error instanceof RequestIncident) this.requestIncident(error);
      else if (!(error instanceof AccessError)) this.incident(error);
      const refusal =
        error instanceof AccessError
          ? error
          : new AccessError(503, "service_unavailable");
      socket.send(
        JSON.stringify({
          type: "error",
          status: refusal.status,
          code: refusal.code,
          id,
        }),
      );
    } finally {
      voicesAbort.abort();
      await voices;
      state.upload?.releaseKeptAudio();
      if (waitingForVoices) this.voiceStreams--;
      socket.close(1000);
      state.release();
      this.finishFailure();
    }
  }

  private async voices(
    upload: StreamUpload,
    signal: AbortSignal,
    id: string,
  ): Promise<Record<string, unknown>> {
    const started = performance.now();
    const audio = upload.keptAudio;
    const definition = upload.voicesDefinition;
    const bytes = audio?.reduce((total, chunk) => total + chunk.length, 0) ?? 0;
    let code = "ok";
    try {
      if (!audio?.length || !definition) throw new Error("voices_unavailable");
      if (!this.admissionOpen || !this.healthy)
        throw new Error("service_unavailable");
      const boundary = randomUUID();
      const parts = [
        Buffer.from(
          `--${boundary}\r\nContent-Disposition: form-data; name="definition"\r\n\r\n${definition}\r\n--${boundary}\r\nContent-Disposition: form-data; name="audio"; filename="recording.wav"\r\nContent-Type: audio/wav\r\n\r\n`,
        ),
        wavHeader(bytes),
        ...audio,
        Buffer.from(`\r\n--${boundary}--\r\n`),
      ];
      const response = await fetch(
        `${this.config.routerOrigin}${transcriptionPath}?api-version=2025-10-15`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${this.config.routerKey}`,
            "Content-Type": `multipart/form-data; boundary=${boundary}`,
          },
          body: new ReadableStream<Uint8Array>({
            pull(controller) {
              const part = parts.shift();
              if (part) controller.enqueue(part);
              else controller.close();
            },
          }),
          signal: AbortSignal.any([
            signal,
            AbortSignal.timeout(voicesTimeoutMs),
          ]),
          redirect: "error",
        },
      );
      if (!response.ok) {
        await response.body?.cancel();
        throw new Error(`upstream_${response.status}`);
      }
      const result = record(
        parseJSON(
          new TextDecoder("utf-8", { fatal: true }).decode(
            await boundedBytes(response.body, diarizedResultBytes, signal),
          ),
        ),
      );
      const transcript = this.transcript(result, true);
      return {
        type: "voices",
        text: transcript.texts.join("\n"),
        phrases: transcript.phrases,
      };
    } catch (error) {
      code = signal.aborted
        ? "client_closed"
        : error instanceof Error && /^[a-z0-9_]+$/.test(error.message)
          ? error.message
          : "voices_failed";
      return { type: "voices_unavailable" };
    } finally {
      console.log(
        JSON.stringify({
          event: "voices",
          id,
          code,
          ms: Math.round(performance.now() - started),
          audio_ms: Math.round((bytes / 2 / sampleRate) * 1000),
        }),
      );
    }
  }

  private transcript(
    result: Record<string, unknown>,
    diarized: boolean,
  ): Transcript {
    if (
      !Array.isArray(result.combinedPhrases) ||
      result.combinedPhrases.some(
        (phrase) => typeof record(phrase).text !== "string",
      )
    )
      throw new Error("Invalid provider result");
    return {
      texts: (result.combinedPhrases as unknown[]).map(
        (phrase) => record(phrase).text as string,
      ),
      phrases: diarized ? voicePhrases(result) : undefined,
    };
  }

  private async verifying<T>(
    checks: Set<AbortController>,
    request: Request,
    limit: number,
    read: (body: Record<string, unknown>) => unknown,
    work: (value: string) => Promise<T>,
  ) {
    const abort = new AbortController();
    const signal = AbortSignal.any([request.signal, abort.signal]);
    checks.add(abort);
    try {
      const body = await jsonBody(
        request,
        limit,
        AbortSignal.any([signal, AbortSignal.timeout(2000)]),
      );
      const value = read(body);
      if (typeof value !== "string" || !value)
        throw new AccessError(400, "invalid_request");
      const result = await work(value);
      if (!this.admissionOpen || !this.healthy)
        throw new AccessError(503, "service_unavailable");
      return result;
    } catch (error) {
      if (abort.signal.aborted)
        throw new AccessError(503, "service_unavailable");
      throw error;
    } finally {
      checks.delete(abort);
    }
  }

  private async purchase(request: Request, session: Session) {
    const transaction = await this.verifying(
      this.purchaseChecks,
      request,
      16 * 1024,
      (body) => {
        exactKeys(body, ["signed_transaction"]);
        return body.signed_transaction;
      },
      (jws) => this.purchases.transaction(jws),
    );
    return json({
      allowance: this.store.purchase(session, transaction, Date.now()),
    });
  }

  private async notification(request: Request) {
    if (this.notifications.size >= 8)
      throw new AccessError(503, "service_busy");
    const transaction = await this.verifying(
      this.notifications,
      request,
      64 * 1024,
      (body) => body.signedPayload,
      (payload) => this.purchases.notification(payload),
    );
    if (transaction) this.store.notify(transaction, Date.now());
    return new Response(null, {
      status: 200,
      headers: { "Cache-Control": "no-store" },
    });
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
      return json(
        this.store.enroll(identity, Date.now(), platform(request)),
        201,
      );
    } catch (error) {
      if (error instanceof OperatorIncident) throw error;
      if (abort.signal.aborted)
        throw new AccessError(503, "service_unavailable");
      throw error;
    } finally {
      this.enrollments.delete(abort);
    }
  }

  private async transcribe(
    grant: Grant,
    client: AbortSignal,
    input: (signal: AbortSignal) => AudioInput,
    now: number,
    route: "stream" | "upload",
    id: string,
    origin: Platform,
  ): Promise<Transcript> {
    const phases = new Phases();
    let upload: AudioInput | undefined;
    let result: { status: number; code: string } = { status: 200, code: "ok" };
    try {
      return await this.forward(
        grant,
        client,
        (signal) => {
          upload = input(signal);
          return upload;
        },
        now,
        phases,
        origin,
      );
    } catch (error) {
      const refusal =
        error instanceof AccessError ||
        error instanceof OperatorIncident ||
        !upload?.bodyHandedOff
          ? error
          : new AccessError(502, "transcription_failed");
      result = client.aborted
        ? { status: 499, code: "client_closed" }
        : outcome(refusal);
      if (refusal !== error) this.incident(error);
      throw refusal;
    } finally {
      if (upload?.audioEndedAt !== undefined)
        phases.mark("audio_end", upload.audioEndedAt);
      phases.mark("settled");
      console.log(
        JSON.stringify({
          event: "dictation",
          id,
          route,
          ...result,
          audio_ms: Math.round(((upload?.samples ?? 0) * 1000) / sampleRate),
          ...phases.marks,
        }),
      );
    }
  }

  private async forward(
    grant: Grant,
    client: AbortSignal,
    input: (signal: AbortSignal) => AudioInput,
    now: number,
    phases: Phases,
    origin: Platform,
  ): Promise<Transcript> {
    const abort = new AbortController();
    this.pendingUploads.set(grant.hash, abort);
    const deadline = AbortSignal.timeout(Math.max(1, grant.deadline - now));
    const signal = AbortSignal.any([client, abort.signal, deadline]);
    let upload: AudioInput | undefined;
    let charge = false;
    let upstreamRefused = false;
    let inputRejected = false;
    let refusedDispatch = false;
    try {
      upload = input(signal);
      const prepared = await upload.prepare(() => {
        if (abort.signal.aborted || !this.admissionOpen || !this.healthy) {
          refusedDispatch = true;
          throw new AccessError(503, "service_unavailable");
        }
        this.pendingUploads.delete(grant.hash);
        this.uploads.add(grant.hash);
        phases.mark("dispatch");
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
      phases.mark("upstream");
      if (!response.ok) {
        upstreamRefused = true;
        await response.body?.cancel();
        if ([401, 403].includes(response.status))
          throw new OperatorIncident("router_credentials_rejected");
        inputRejected = [400, 422].includes(response.status);
        throw new AccessError(502, "transcription_failed");
      }
      let transcript: Transcript;
      try {
        const bytes = await boundedBytes(
          response.body,
          upload.diarized ? diarizedResultBytes : 1024 * 1024,
          uploadSignal,
        );
        transcript = this.transcript(
          record(
            parseJSON(new TextDecoder("utf-8", { fatal: true }).decode(bytes)),
          ),
          upload.diarized,
        );
        if (!upload.isComplete) throw new Error("Invalid provider result");
      } catch (error) {
        if (client.aborted) throw error;
        upstreamRefused = true;
        throw new AccessError(502, "transcription_failed");
      }
      charge = true;
      return transcript;
    } catch (error) {
      const clientFailure =
        client.aborted ||
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
          Date.now(),
          origin,
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
    for (const check of this.notifications) check.abort();
    for (const check of this.purchaseChecks) check.abort();
    for (const upload of this.pendingUploads.values()) upload.abort();
  }
}
