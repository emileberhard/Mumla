import { afterAll, afterEach, expect, spyOn, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AccessConfig } from "../src/config";
import { AccessService } from "../src/server";
import { AccessStore } from "../src/store";
import { KeptAudioBudget, StreamUpload } from "../src/stream";
import { syntheticPolicy, syntheticVerifier } from "./appstore-fixture";

const resources: (() => void | Promise<void>)[] = [];
const logged: Record<string, unknown>[] = [];
const consoleLog = spyOn(console, "log").mockImplementation((line: unknown) => {
  if (typeof line === "string" && line.startsWith("{"))
    logged.push(JSON.parse(line));
});
afterEach(async () => {
  for (const cleanup of resources.splice(0).reverse()) await cleanup();
});
afterAll(() => consoleLog.mockRestore());

const operatorToken = "synthetic-operator-token-with-32-characters";
const BunWebSocket = WebSocket as unknown as new (
  url: string | URL,
  options: Bun.WebSocketOptions,
) => WebSocket;

async function setup(upstream: (request: Request) => Promise<Response>) {
  const router = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      if (new URL(request.url).pathname === "/health")
        return Response.json({ service: "llm-router", status: "ok" });
      return upstream(request);
    },
  });
  resources.push(() => router.stop(true));
  const directory = mkdtempSync(join(tmpdir(), "mumla-stream-test-"));
  resources.push(() => rmSync(directory, { recursive: true, force: true }));
  const config: AccessConfig = {
    listenPort: 10240,
    database: join(directory, "access.sqlite"),
    cloudKitContainer: "iCloud.example.synthetic",
    cloudKitAPIToken: "synthetic-api-token",
    routerOrigin: router.url.origin,
    routerKey: "synthetic-router-key",
    operatorToken,
    freeMonthlySeconds: 600,
    subjectOverrides: {},
    ...syntheticPolicy,
  };
  const store = new AccessStore(config.database, config, "initialize");
  resources.push(() => store.close());
  const service = new AccessService(
    config,
    {
      async check() {
        return true;
      },
      async verify() {
        return "verified-apple-identity";
      },
    },
    syntheticVerifier(),
    store,
    { version: "1.2.3", commit: "abc123" },
    () => {},
  );
  await service.check();
  const server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request, server) {
      return service.handle(
        request,
        request.headers.get("cf-connecting-ip"),
        server,
      );
    },
    websocket: service.websocket,
  });
  resources.push(() => server.stop(true));
  const call = (path: string, method = "GET", token?: string, body?: unknown) =>
    fetch(new URL(path, server.url), {
      method,
      headers: {
        "CF-Connecting-IP": "192.0.2.1",
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
  expect((await call("/internal/reopen", "POST", operatorToken)).status).toBe(
    200,
  );
  const session = await (
    await call("/v1/sessions", "POST", undefined, {
      web_auth_token: "apple-proof",
    })
  ).json();
  const grant = async (seconds: number) =>
    (
      await call("/v1/dictations", "POST", session.token, {
        maximum_audio_seconds: seconds,
      })
    ).json();
  const used = async () =>
    (await (await call("/v1/access", "GET", session.token)).json()).allowance;
  const open = (token: string) => {
    const socket = new BunWebSocket(
      new URL("/v1/dictations/stream", server.url.href.replace("http", "ws")),
      { headers: { Authorization: `Bearer ${token}` } },
    );
    socket.binaryType = "arraybuffer";
    const messages: unknown[] = [];
    const closed = new Promise<unknown[]>((resolve) => {
      socket.addEventListener("message", (event) =>
        messages.push(JSON.parse(String(event.data))),
      );
      socket.addEventListener("close", () => resolve(messages));
    });
    const opened = new Promise<void>((resolve, reject) => {
      socket.addEventListener("open", () => resolve());
      socket.addEventListener("error", () => reject(new Error("handshake")));
    });
    return { socket, opened, closed };
  };
  return { call, service, store, server, grant, used, open };
}

function reading(minimumBytes: number) {
  const reached = Promise.withResolvers<void>();
  const upstream = async (request: Request) => {
    const reader = request.body?.getReader();
    if (!reader) throw new Error("Missing upstream body");
    let total = 0;
    try {
      while (true) {
        const next = await reader.read();
        if (next.done) break;
        total += next.value.length;
        if (total >= minimumBytes) reached.resolve();
      }
    } catch {}
    return Response.json({ combinedPhrases: [] });
  };
  return { reached: reached.promise, upstream };
}

function pcm(samples: number, value = 1) {
  const audio = Buffer.alloc(samples * 2);
  for (let index = 0; index < samples; index++)
    audio.writeInt16LE(value, index * 2);
  return audio;
}

async function multipartAudio(request: Request) {
  const body = Buffer.from(await request.arrayBuffer());
  const form = await new Response(body, {
    headers: { "Content-Type": request.headers.get("content-type") ?? "" },
  }).formData();
  const audio = Buffer.from(
    await (form.get("audio") as unknown as Blob).arrayBuffer(),
  );
  return {
    definition: JSON.parse(String(form.get("definition"))),
    header: audio.subarray(0, 44),
    pcm: audio.subarray(44),
  };
}

test("a dictation streams over one socket and the service builds the provider definition", async () => {
  let received: Awaited<ReturnType<typeof multipartAudio>> | undefined;
  const { grant, used, open } = await setup(async (request) => {
    expect(request.headers.get("authorization")).toBe(
      "Bearer synthetic-router-key",
    );
    received = await multipartAudio(request);
    return Response.json({
      combinedPhrases: [{ text: "First line." }, { text: "Second line." }],
    });
  });
  const reserved = await grant(1800);
  expect(reserved.audio_limit_samples).toBe(600 * 16_000);
  const { socket, opened, closed } = open(reserved.token);
  await opened;
  socket.send(
    JSON.stringify({
      type: "start",
      languages: [" sv "],
      vocabulary: ["synthetic", "x".repeat(51), " ", "Lund"],
    }),
  );
  socket.send(pcm(16_000, 7));
  socket.send(pcm(8_000, 9));
  socket.send(JSON.stringify({ type: "finish" }));
  expect(await closed).toEqual([
    {
      type: "result",
      text: "First line.\nSecond line.",
      id: expect.any(String),
    },
  ]);
  expect(received?.definition).toEqual({
    enhancedMode: {
      enabled: true,
      model: "MAI-Transcribe-2",
      modelOptions: { transcribeStyle: "clean", timestamps: "none" },
    },
    phraseList: { phrases: ["synthetic", "Lund"] },
    locales: ["sv"],
  });
  expect(received?.header.readUInt32LE(40)).toBe(0xffff_ffff);
  expect(received?.pcm).toEqual(Buffer.concat([pcm(16_000, 7), pcm(8_000, 9)]));
  expect(await used()).toMatchObject({ used_seconds: 2, in_flight_seconds: 0 });
  const [reply] = (await closed) as { id: string }[];
  const line = logged.find((entry) => entry.id === reply?.id);
  expect(line).toMatchObject({
    event: "dictation",
    route: "stream",
    status: 200,
    code: "ok",
    audio_ms: 1500,
  });
  const mark = (name: string) => line?.[`${name}_ms`] as number;
  expect(mark("dispatch")).toBeLessThanOrEqual(mark("upstream"));
  expect(mark("audio_end")).toBeLessThanOrEqual(mark("upstream"));
  expect(mark("upstream")).toBeLessThanOrEqual(mark("settled"));
});

test("several languages leave detection to the provider", async () => {
  let definition: unknown;
  const { grant, open } = await setup(async (request) => {
    definition = (await multipartAudio(request)).definition;
    return Response.json({ combinedPhrases: [] });
  });
  const { socket, opened, closed } = open((await grant(10)).token);
  await opened;
  socket.send(
    JSON.stringify({ type: "start", languages: ["en", "sv"], vocabulary: [] }),
  );
  socket.send(pcm(160));
  socket.send(JSON.stringify({ type: "finish" }));
  expect(await closed).toEqual([
    { type: "result", text: "", id: expect.any(String) },
  ]);
  expect(definition).toEqual({
    enhancedMode: {
      enabled: true,
      model: "MAI-Transcribe-2",
      modelOptions: { transcribeStyle: "clean", timestamps: "none" },
    },
  });
});

test("an invalid grant or another upgrade is refused before the handshake", async () => {
  const { service, grant } = await setup(async () => {
    throw new Error("unreachable");
  });
  const upgrader = {
    upgrade() {
      throw new Error("must not upgrade");
    },
  };
  const request = (path: string, token: string) =>
    new Request(`http://localhost${path}`, {
      headers: { Upgrade: "websocket", Authorization: `Bearer ${token}` },
    });
  const invalid = await service.handle(
    request("/v1/dictations/stream", "A".repeat(43)),
    null,
    upgrader,
  );
  expect(invalid?.status).toBe(401);
  const elsewhere = await service.handle(
    request("/v1/access", (await grant(10)).token),
    null,
    upgrader,
  );
  expect(elsewhere?.status).toBe(400);
});

test("fencing an undispatched stream refuses it with a retryable 503 and no charge", async () => {
  const { call, grant, used, open } = await setup(async () => {
    throw new Error("unreachable");
  });
  const { opened, closed } = open((await grant(30)).token);
  await opened;
  expect((await call("/internal/fence", "POST", operatorToken)).status).toBe(
    200,
  );
  expect(await closed).toEqual([
    {
      type: "error",
      status: 503,
      code: "service_unavailable",
      id: expect.any(String),
    },
  ]);
  await call("/internal/reopen", "POST", operatorToken);
  expect(await used()).toMatchObject({ used_seconds: 0, in_flight_seconds: 0 });
});

test("audio past the grant is refused and the forwarded part is charged", async () => {
  const upstream = reading(64_000);
  const { grant, used, open } = await setup(upstream.upstream);
  const { socket, opened, closed } = open((await grant(2)).token);
  await opened;
  socket.send(JSON.stringify({ type: "start", languages: [], vocabulary: [] }));
  socket.send(pcm(32_000));
  await upstream.reached;
  socket.send(pcm(1));
  expect(await closed).toEqual([
    {
      type: "error",
      status: 413,
      code: "audio_limit_exceeded",
      id: expect.any(String),
    },
  ]);
  expect(await used()).toMatchObject({ used_seconds: 2, in_flight_seconds: 0 });
});

test("a client that disconnects after dispatch is charged for what was forwarded", async () => {
  const upstream = reading(48_000);
  const { grant, used, open } = await setup(upstream.upstream);
  const { socket, opened, closed } = open((await grant(30)).token);
  await opened;
  socket.send(JSON.stringify({ type: "start", languages: [], vocabulary: [] }));
  socket.send(pcm(24_000));
  await upstream.reached;
  const before = logged.length;
  socket.close();
  await closed;
  for (let attempt = 0; attempt < 50; attempt++) {
    if ((await used()).in_flight_seconds === 0) break;
    await Bun.sleep(20);
  }
  expect(await used()).toMatchObject({ used_seconds: 2, in_flight_seconds: 0 });
  expect(
    logged.slice(before).filter((entry) => entry.event === "dictation"),
  ).toMatchObject([{ route: "stream", status: 499, code: "client_closed" }]);
});

test("a burst faster than the provider reads is paused, not dropped or timed out", async () => {
  let forwarded = Buffer.alloc(0);
  const { grant, open } = await setup(async (request) => {
    const reader = request.body?.getReader();
    if (!reader) throw new Error("Missing upstream body");
    const parts: Buffer[] = [];
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      parts.push(Buffer.from(next.value));
      await Bun.sleep(1);
    }
    forwarded = Buffer.concat(parts);
    return Response.json({ combinedPhrases: [{ text: "Burst." }] });
  });
  const { socket, opened, closed } = open((await grant(120)).token);
  await opened;
  socket.send(JSON.stringify({ type: "start", languages: [], vocabulary: [] }));
  const audio = Buffer.alloc(90 * 32_000);
  for (let index = 0; index < audio.length; index += 2)
    audio.writeInt16LE((index / 2) % 30_000, index);
  for (let offset = 0; offset < audio.length; offset += 32_000)
    socket.send(audio.subarray(offset, offset + 32_000));
  socket.send(JSON.stringify({ type: "finish" }));
  expect(await closed).toEqual([
    { type: "result", text: "Burst.", id: expect.any(String) },
  ]);
  expect(forwarded.includes(audio)).toBe(true);
});

test("a settlement failure after dispatch is never reported as retryable", async () => {
  const { store, grant, open } = await setup(async (request) => {
    await request.arrayBuffer();
    return Response.json({ combinedPhrases: [{ text: "Done." }] });
  });
  const { socket, opened, closed } = open((await grant(10)).token);
  await opened;
  store.settle = () => {
    throw Object.assign(new Error("synthetic"), { code: "SQLITE_FULL" });
  };
  socket.send(JSON.stringify({ type: "start", languages: [], vocabulary: [] }));
  socket.send(pcm(160));
  socket.send(JSON.stringify({ type: "finish" }));
  expect(await closed).toEqual([
    {
      type: "error",
      status: 502,
      code: "transcription_failed",
      id: expect.any(String),
    },
  ]);
});

const diarizedDefinition = {
  enhancedMode: {
    enabled: true,
    model: "MAI-Transcribe-2",
    modelOptions: { transcribeStyle: "clean", timestamps: "word" },
  },
  diarization: { enabled: true },
};

const diarizedResult = {
  combinedPhrases: [{ text: "Mine. Theirs." }],
  phrases: [
    {
      speaker: 0,
      text: "Mine.",
      offsetMilliseconds: 0,
      durationMilliseconds: 400,
      words: [
        { text: "Mine.", offsetMilliseconds: 0, durationMilliseconds: 400 },
      ],
    },
    {
      speaker: 1,
      text: "Theirs.",
      offsetMilliseconds: 500,
      durationMilliseconds: 400,
      words: [
        { text: "Theirs.", offsetMilliseconds: 500, durationMilliseconds: 400 },
      ],
    },
  ],
};

const voicesReply = {
  type: "voices",
  text: "Mine. Theirs.",
  phrases: [
    { speaker: 0, text: "Mine.", words: [[0, 400]] },
    { speaker: 1, text: "Theirs.", words: [[500, 400]] },
  ],
  id: expect.any(String),
};

test("a requested voices pass diarizes the kept audio without charging again", async () => {
  const requests: Awaited<ReturnType<typeof multipartAudio>>[] = [];
  const { grant, used, open } = await setup(async (request) => {
    const received = await multipartAudio(request);
    requests.push(received);
    return Response.json(
      received.definition.diarization
        ? diarizedResult
        : { combinedPhrases: [{ text: "Mine. Theirs." }] },
    );
  });
  const { socket, opened, closed } = open((await grant(30)).token);
  await opened;
  socket.send(
    JSON.stringify({
      type: "start",
      languages: [],
      vocabulary: [],
      speakers: "onRequest",
    }),
  );
  socket.send(pcm(16_000, 7));
  socket.send(pcm(8_000, 9));
  socket.send(JSON.stringify({ type: "finish" }));
  socket.send(JSON.stringify({ type: "voices" }));
  const messages = await closed;
  expect(messages).toEqual([
    { type: "result", text: "Mine. Theirs.", id: expect.any(String) },
    voicesReply,
  ]);
  expect(requests).toHaveLength(2);
  const second = requests.find((request) => request.definition.diarization);
  expect(second?.definition).toEqual(diarizedDefinition);
  expect(second?.header.readUInt32LE(40)).toBe(48_000);
  expect(second?.pcm).toEqual(Buffer.concat([pcm(16_000, 7), pcm(8_000, 9)]));
  expect(await used()).toMatchObject({ used_seconds: 2, in_flight_seconds: 0 });
  const [result] = messages as { id: string }[];
  expect(
    logged.find((entry) => entry.event === "voices" && entry.id === result?.id),
  ).toMatchObject({ code: "ok", audio_ms: 1_500 });
});

test("a failed voices pass still delivers the result first", async () => {
  const { grant, open } = await setup(async (request) => {
    const received = await multipartAudio(request);
    if (received.definition.diarization)
      return new Response("busy", { status: 503 });
    return Response.json({ combinedPhrases: [{ text: "Everyone." }] });
  });
  const { socket, opened, closed } = open((await grant(30)).token);
  await opened;
  socket.send(
    JSON.stringify({
      type: "start",
      languages: [],
      vocabulary: [],
      speakers: "onRequest",
    }),
  );
  socket.send(pcm(1_600));
  socket.send(JSON.stringify({ type: "finish" }));
  socket.send(JSON.stringify({ type: "voices" }));
  expect(await closed).toEqual([
    { type: "result", text: "Everyone.", id: expect.any(String) },
    { type: "voices_unavailable", id: expect.any(String) },
  ]);
});

test("diarize mode answers with speaker phrases in one charged request", async () => {
  const definitions: unknown[] = [];
  const { grant, used, open } = await setup(async (request) => {
    definitions.push((await multipartAudio(request)).definition);
    return Response.json(diarizedResult);
  });
  const { socket, opened, closed } = open((await grant(30)).token);
  await opened;
  socket.send(
    JSON.stringify({
      type: "start",
      languages: [],
      vocabulary: [],
      speakers: "diarize",
    }),
  );
  socket.send(pcm(16_000));
  socket.send(JSON.stringify({ type: "finish" }));
  expect(await closed).toEqual([voicesReply]);
  expect(definitions).toEqual([diarizedDefinition]);
  expect(await used()).toMatchObject({ used_seconds: 1, in_flight_seconds: 0 });
});

test("diarize mode with unusable speaker phrases still answers the text", async () => {
  const { grant, open } = await setup(async (request) => {
    await multipartAudio(request);
    return Response.json({
      combinedPhrases: [{ text: "Everyone." }],
      phrases: [{ speaker: -1, text: "Everyone.", words: [] }],
    });
  });
  const { socket, opened, closed } = open((await grant(30)).token);
  await opened;
  socket.send(
    JSON.stringify({
      type: "start",
      languages: [],
      vocabulary: [],
      speakers: "diarize",
    }),
  );
  socket.send(pcm(1_600));
  socket.send(JSON.stringify({ type: "finish" }));
  const messages = await closed;
  expect(messages).toEqual([
    { type: "result", text: "Everyone.", id: expect.any(String) },
  ]);
  const [result] = messages as { id: string }[];
  expect(
    logged.find((entry) => entry.event === "voices" && entry.id === result?.id),
  ).toMatchObject({ code: "phrases_invalid" });
});

test("an on-request stream stays active until it closes unasked after the result", async () => {
  const { call, grant, open } = await setup(async (request) => {
    await multipartAudio(request);
    return Response.json({ combinedPhrases: [{ text: "Mine." }] });
  });
  const active = async () =>
    (await (await call("/internal/status", "GET", operatorToken)).json())
      .active;
  const { socket, opened, closed } = open((await grant(30)).token);
  await opened;
  const result = new Promise<void>((resolve) =>
    socket.addEventListener("message", () => resolve(), { once: true }),
  );
  socket.send(
    JSON.stringify({
      type: "start",
      languages: [],
      vocabulary: [],
      speakers: "onRequest",
    }),
  );
  socket.send(pcm(1_600));
  socket.send(JSON.stringify({ type: "finish" }));
  await result;
  expect(await active()).toBe(1);
  const started = performance.now();
  expect(await closed).toEqual([
    { type: "result", text: "Mine.", id: expect.any(String) },
  ]);
  expect(performance.now() - started).toBeGreaterThan(4_000);
  expect(await active()).toBe(0);
}, 10_000);

test("voices is refused before finish and outside on-request streams", async () => {
  const { grant, open } = await setup(async () =>
    Response.json({ combinedPhrases: [] }),
  );
  for (const speakers of ["onRequest", undefined]) {
    const { socket, opened, closed } = open((await grant(30)).token);
    await opened;
    socket.send(
      JSON.stringify({
        type: "start",
        languages: [],
        vocabulary: [],
        speakers,
      }),
    );
    if (!speakers) {
      socket.send(pcm(160));
      socket.send(JSON.stringify({ type: "finish" }));
    }
    socket.send(JSON.stringify({ type: "voices" }));
    expect(await closed).toMatchObject([
      { type: "error", status: 400, code: "invalid_message" },
    ]);
  }
});

test("kept audio past the shared budget is released and never sent", () => {
  const budget = new KeptAudioBudget(100);
  const upload = new StreamUpload(
    { pause() {}, resume() {} },
    16_000,
    new AbortController().signal,
    budget,
  );
  upload.receive(
    JSON.stringify({
      type: "start",
      languages: [],
      vocabulary: [],
      speakers: "onRequest",
    }),
  );
  upload.receive(pcm(32));
  expect(upload.keptAudio?.length).toBe(1);
  upload.receive(pcm(32));
  expect(upload.keptAudio).toBeUndefined();
  expect(budget.reserve(100)).toBe(true);
  upload.close();
});
