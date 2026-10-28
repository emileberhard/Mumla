import { afterEach, expect, spyOn, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AccessConfig } from "../src/config";
import { transcriptionPath } from "../src/protocol";
import { AccessService } from "../src/server";
import { AccessStore } from "../src/store";
import { TranscriptionUpload } from "../src/transcription";

const resources: (() => void | Promise<void>)[] = [];
afterEach(async () => {
  for (const cleanup of resources.splice(0).reverse()) await cleanup();
});
const options = {
  enhancedMode: {
    enabled: true,
    model: "MAI-Transcribe-2",
    modelOptions: { transcribeStyle: "clean", timestamps: "none" },
  },
  locales: ["sv-SE"],
  phraseList: { phrases: ["synthetic"] },
};

function wav(samples: number, streaming = false) {
  const header = Buffer.alloc(44);
  header.write("RIFF");
  header.writeUInt32LE(streaming ? 0xffffffff : 36 + samples * 2, 4);
  header.write("WAVEfmt ", 8);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(1, 22);
  header.writeUInt32LE(16_000, 24);
  header.writeUInt32LE(32_000, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(streaming ? 0xffffffff : samples * 2, 40);
  return Buffer.concat([header, Buffer.alloc(samples * 2)]);
}

function multipart(
  audio: Uint8Array,
  definition: unknown = options,
  trailing = "",
) {
  const boundary = "synthetic-boundary";
  const prefix = Buffer.from(
    `--${boundary}\r\nContent-Disposition: form-data; name="definition"\r\n\r\n${JSON.stringify(definition)}\r\n--${boundary}\r\nContent-Disposition: form-data; name="audio"; filename="recording.wav"\r\nContent-Type: audio/wav\r\n\r\n`,
  );
  return {
    contentType: `multipart/form-data; boundary=${boundary}`,
    bytes: Buffer.concat([
      prefix,
      audio,
      Buffer.from(`\r\n--${boundary}--\r\n${trailing}`),
    ]),
  };
}

async function setup(
  upstream: (request: Request) => Promise<Response>,
  onFatal: () => void = () => {},
) {
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
  const directory = mkdtempSync(join(tmpdir(), "mumla-http-test-"));
  resources.push(() => rmSync(directory, { recursive: true, force: true }));
  const config: AccessConfig = {
    listenPort: 10240,
    database: join(directory, "access.sqlite"),
    cloudKitContainer: "iCloud.example.synthetic",
    cloudKitAPIToken: "synthetic-api-token",
    routerOrigin: router.url.origin,
    routerKey: "synthetic-router-key",
    operatorToken: "synthetic-operator-token-with-32-characters",
    freeMonthlySeconds: 60,
    subjectOverrides: {},
  };
  const store = new AccessStore(config.database, config, "initialize");
  resources.push(() => store.close());
  const service = new AccessService(
    config,
    {
      async check() {
        return true;
      },
      async verify(token) {
        if (token !== "apple-proof") throw new Error("unexpected proof");
        return "verified-apple-identity";
      },
    },
    store,
    { version: "1.2.3", commit: "abc123" },
    onFatal,
  );
  await service.check();
  const server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request) {
      return service.handle(request, request.headers.get("cf-connecting-ip"));
    },
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
  expect((await call("/healthz")).status).toBe(503);
  expect(
    (await call("/internal/reopen", "POST", config.operatorToken)).status,
  ).toBe(200);
  const session = await (
    await call("/v1/sessions", "POST", undefined, {
      web_auth_token: "apple-proof",
    })
  ).json();
  return { call, session, config, server, service, store, router };
}

test("real HTTP admission, rebuilt upload, metering, rotation and idle fence", async () => {
  let received: FormData | undefined;
  const { call, session, config, server } = await setup(async (request) => {
    expect(request.headers.get("authorization")).toBe(
      "Bearer synthetic-router-key",
    );
    received = await request.formData();
    return Response.json({
      combinedPhrases: [{ text: "Synthetic result." }],
      ignored: "private-provider-metadata",
    });
  });
  const grant = await (
    await call("/v1/dictations", "POST", session.token, {
      maximum_audio_seconds: 10,
    })
  ).json();
  expect(
    (await call("/internal/status", "GET", config.operatorToken)).status,
  ).toBe(200);
  expect((await call("/healthz")).status).toBe(200);
  const input = multipart(wav(16_001));
  const result = await fetch(
    new URL(`${transcriptionPath}?api-version=2025-10-15`, server.url),
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${grant.token}`,
        "Content-Type": input.contentType,
      },
      body: input.bytes,
    },
  );
  expect(result.status).toBe(200);
  expect(await result.json()).toEqual({
    combinedPhrases: [{ text: "Synthetic result." }],
  });
  expect(received?.get("definition")).toBe(JSON.stringify(options));
  expect((received?.get("audio") as File | undefined)?.size).toBe(32_046);
  const access = await (await call("/v1/access", "GET", session.token)).json();
  expect(access.allowance.used_seconds).toBe(2);
  expect(access.allowance.reserved_seconds).toBe(0);
  expect(
    (await call("/internal/fence", "POST", config.operatorToken)).status,
  ).toBe(200);
  expect((await call("/healthz")).status).toBe(503);
  expect(
    (await call("/internal/reopen", "POST", config.operatorToken)).status,
  ).toBe(200);
});

test.each([
  [
    "unapproved model",
    multipart(wav(100), {
      enhancedMode: {
        enabled: true,
        model: "other",
        modelOptions: { transcribeStyle: "clean" },
      },
    }),
    "unsupported_transcription",
  ],
  [
    "invalid sample rate",
    (() => {
      const audio = wav(100);
      audio.writeUInt32LE(48_000, 24);
      return multipart(audio);
    })(),
    "invalid_audio",
  ],
  [
    "declared length beyond grant",
    (() => {
      const audio = wav(100);
      audio.writeUInt32LE(36 + 160_001 * 2, 4);
      audio.writeUInt32LE(160_001 * 2, 40);
      return multipart(audio);
    })(),
    "invalid_audio",
  ],
  [
    "malformed definition JSON",
    (() => {
      const input = multipart(wav(100));
      return {
        ...input,
        bytes: Buffer.from(
          input.bytes.toString().replace(JSON.stringify(options), "{"),
        ),
      };
    })(),
    "invalid_json",
  ],
])(
  "refuses %s before upstream dispatch and charges the one-second minimum",
  async (_label, input, code) => {
    let calls = 0;
    const { call, session, server } = await setup(async () => {
      calls++;
      return new Response(null, { status: 500 });
    });
    const grant = await (
      await call("/v1/dictations", "POST", session.token, {
        maximum_audio_seconds: 10,
      })
    ).json();
    const response = await fetch(
      new URL(`${transcriptionPath}?api-version=2025-10-15`, server.url),
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${grant.token}`,
          "Content-Type": input.contentType,
        },
        body: input.bytes,
      },
    );
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: { code } });
    expect(calls).toBe(0);
    const access = await (
      await call("/v1/access", "GET", session.token)
    ).json();
    expect(access.allowance.used_seconds).toBe(1);
    expect(access.allowance.reserved_seconds).toBe(0);
  },
);

test("unknown-length input reaches the upstream before capture completes", async () => {
  const receivedPrefix = Promise.withResolvers<void>();
  const finishCapture = Promise.withResolvers<void>();
  const { call, session, server } = await setup(async (request) => {
    const reader = request.body?.getReader();
    if (!reader) throw new Error("Missing upstream body");
    const first = await reader.read();
    expect(first.done).toBe(false);
    receivedPrefix.resolve();
    while (!(await reader.read()).done) {}
    return Response.json({ combinedPhrases: [{ text: "Streamed result." }] });
  });
  const grant = await (
    await call("/v1/dictations", "POST", session.token, {
      maximum_audio_seconds: 10,
    })
  ).json();
  const input = multipart(wav(16_000, true));
  let sent = false;
  const body = new ReadableStream<Uint8Array>({
    async pull(controller) {
      if (!sent) {
        sent = true;
        controller.enqueue(input.bytes.subarray(0, 1000));
        return;
      }
      await finishCapture.promise;
      controller.enqueue(input.bytes.subarray(1000));
      controller.close();
    },
  });
  const pending = fetch(
    new URL(`${transcriptionPath}?api-version=2025-10-15`, server.url),
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${grant.token}`,
        "Content-Type": input.contentType,
      },
      body,
    },
  );
  try {
    await receivedPrefix.promise;
    const status = await (
      await call(
        "/internal/status",
        "GET",
        "synthetic-operator-token-with-32-characters",
      )
    ).json();
    expect(status.active).toBe(1);
  } finally {
    finishCapture.resolve();
  }
  const response = await pending;
  expect(response.status).toBe(200);
  expect(
    (await (await call("/v1/access", "GET", session.token)).json()).allowance
      .used_seconds,
  ).toBe(1);
});

test("early upstream rejection stops an unfinished client body and releases the reservation", async () => {
  const { call, session, server } = await setup(
    async () => new Response(null, { status: 429 }),
  );
  const grant = await (
    await call("/v1/dictations", "POST", session.token, {
      maximum_audio_seconds: 10,
    })
  ).json();
  const input = multipart(wav(16_000, true));
  const finish = Promise.withResolvers<void>();
  let sent = false;
  const body = new ReadableStream<Uint8Array>({
    async pull(controller) {
      if (!sent) {
        sent = true;
        controller.enqueue(input.bytes.subarray(0, 1000));
        return;
      }
      await finish.promise;
      controller.close();
    },
    cancel() {
      finish.resolve();
    },
  });
  try {
    const response = await fetch(
      new URL(`${transcriptionPath}?api-version=2025-10-15`, server.url),
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${grant.token}`,
          "Content-Type": input.contentType,
        },
        body,
      },
    );
    expect(response.status).toBe(502);
    const access = await (
      await call("/v1/access", "GET", session.token)
    ).json();
    expect(access.allowance.reserved_seconds).toBe(0);
    expect(access.allowance.used_seconds).toBe(0);
  } finally {
    finish.resolve();
  }
});

test("SpeechKit's encoded progressive request accepts omitted timestamps and normalizes them", async () => {
  const fixture = new URL("fixtures/", import.meta.url);
  const definition = await Bun.file(
    new URL("speechkit-definition.json", fixture),
  ).json();
  let forwarded: FormData | undefined;
  const { call, session, server } = await setup(async (request) => {
    forwarded = await request.formData();
    return Response.json({
      combinedPhrases: [{ text: "Synthetic SDK result." }],
    });
  });
  const grant = await (
    await call("/v1/dictations", "POST", session.token, {
      maximum_audio_seconds: 10,
    })
  ).json();
  const response = await fetch(
    new URL(`${transcriptionPath}?api-version=2025-10-15`, server.url),
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${grant.token}`,
        "Content-Type": (
          await Bun.file(new URL("speechkit-content-type.txt", fixture)).text()
        ).trim(),
      },
      body: Bun.file(new URL("speechkit-progressive.bin", fixture)),
    },
  );
  expect(response.status).toBe(200);
  expect(definition.enhancedMode.modelOptions).toEqual({
    transcribeStyle: "clean",
  });
  expect(JSON.parse(String(forwarded?.get("definition")))).toEqual({
    ...definition,
    enhancedMode: {
      ...definition.enhancedMode,
      modelOptions: { transcribeStyle: "clean", timestamps: "none" },
    },
  });
  expect((forwarded?.get("audio") as File | undefined)?.size).toBe(244);
});

test.each([401, 402, 403, 404, 408, 413, 429, 500, 503, 200])(
  "upstream refusal or invalid result %s never spends allowance",
  async (status) => {
    let fatal = false;
    const { call, session, server, service, store } = await setup(
      async (request) => {
        await request.arrayBuffer();
        return new Response(
          status === 200
            ? '{"combinedPhrases":[] ,"combinedPhrases":[]}'
            : null,
          { status },
        );
      },
      () => {
        fatal = true;
      },
    );
    const grant = await (
      await call("/v1/dictations", "POST", session.token, {
        maximum_audio_seconds: 10,
      })
    ).json();
    const input = multipart(wav(16_000));
    const result = await fetch(
      new URL(`${transcriptionPath}?api-version=2025-10-15`, server.url),
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${grant.token}`,
          "Content-Type": input.contentType,
        },
        body: input.bytes,
      },
    );
    expect(result.status).toBe([401, 403].includes(status) ? 503 : 502);
    expect(await result.json()).toEqual({
      error: {
        code: [401, 403].includes(status)
          ? "service_unavailable"
          : "transcription_failed",
      },
    });
    expect(
      store.access(store.authenticate(session.token, Date.now()), Date.now())
        .used_seconds,
    ).toBe(0);
    expect(
      store.access(store.authenticate(session.token, Date.now()), Date.now())
        .reserved_seconds,
    ).toBe(0);
    expect(fatal).toBe([401, 403].includes(status));
    if (fatal)
      expect(
        (await service.handle(new Request("http://localhost/healthz"), null))
          .status,
      ).toBe(503);
  },
);

test.each([400, 422])(
  "provider input refusal %s charges the one-second minimum",
  async (status) => {
    const { call, session, server } = await setup(async (request) => {
      await request.arrayBuffer();
      return new Response(null, { status });
    });
    const grant = await (
      await call("/v1/dictations", "POST", session.token, {
        maximum_audio_seconds: 10,
      })
    ).json();
    const input = multipart(wav(80_000));
    const result = await fetch(
      new URL(`${transcriptionPath}?api-version=2025-10-15`, server.url),
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${grant.token}`,
          "Content-Type": input.contentType,
        },
        body: input.bytes,
      },
    );
    expect(result.status).toBe(502);
    expect(await result.json()).toEqual({
      error: { code: "transcription_failed" },
    });
    expect(
      (await (await call("/v1/access", "GET", session.token)).json()).allowance,
    ).toMatchObject({ used_seconds: 1, reserved_seconds: 0 });
  },
);

test("router connection failure releases the hold without charging", async () => {
  const { call, session, server, router } = await setup(
    async () => new Response(),
  );
  const grant = await (
    await call("/v1/dictations", "POST", session.token, {
      maximum_audio_seconds: 10,
    })
  ).json();
  await router.stop(true);
  const input = multipart(wav(16_000));
  const response = await fetch(
    new URL(`${transcriptionPath}?api-version=2025-10-15`, server.url),
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${grant.token}`,
        "Content-Type": input.contentType,
      },
      body: input.bytes,
    },
  );
  expect(response.status).toBe(502);
  expect(await response.json()).toEqual({
    error: { code: "transcription_failed" },
  });
  expect(
    (await (await call("/v1/access", "GET", session.token)).json()).allowance,
  ).toMatchObject({ used_seconds: 0, reserved_seconds: 0 });
});

test("idle fence revokes unused grants without waiting or charging", async () => {
  const { call, session, config, store } = await setup(
    async () => new Response(),
  );
  const grant = await (
    await call("/v1/dictations", "POST", session.token, {
      maximum_audio_seconds: 10,
    })
  ).json();
  expect(
    (await (await call("/internal/status", "GET", config.operatorToken)).json())
      .active,
  ).toBe(0);
  expect(
    (await call("/internal/fence", "POST", config.operatorToken)).status,
  ).toBe(200);
  expect(() => store.claim(grant.token, Date.now())).toThrow("invalid_grant");
  expect(
    store.access(store.authenticate(session.token, Date.now()), Date.now()),
  ).toMatchObject({
    used_seconds: 0,
    reserved_seconds: 0,
  });
});

test("one account cannot hold the data pool and its grant bodies time out promptly", async () => {
  const { service, session, config, store } = await setup(
    async () => new Response(),
  );
  let read = false;
  const unread = () =>
    new ReadableStream<Uint8Array>(
      {
        pull() {
          read = true;
        },
      },
      { highWaterMark: 0 },
    );
  const unauthenticated = await Promise.all(
    Array.from({ length: 65 }, () =>
      service.handle(
        new Request("http://localhost/v1/dictations", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: unread(),
        }),
        null,
      ),
    ),
  );
  for (const response of unauthenticated) {
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({
      error: { code: "invalid_credential" },
    });
  }
  expect(read).toBe(false);
  const abort = new AbortController();
  const pending = Array.from({ length: 4 }, () =>
    service.handle(
      new Request("http://localhost/v1/dictations", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${session.token}`,
        },
        body: unread(),
        signal: abort.signal,
      }),
      null,
    ),
  );
  try {
    const otherDevice = store.enroll("verified-apple-identity", Date.now());
    const busy = await service.handle(
      new Request("http://localhost/v1/access", {
        headers: { Authorization: `Bearer ${otherDevice.token}` },
      }),
      null,
    );
    expect(busy.status).toBe(503);
    expect(await busy.json()).toEqual({ error: { code: "service_busy" } });
    const otherAccount = store.enroll("another-apple-account", Date.now());
    const served = await service.handle(
      new Request("http://localhost/v1/dictations", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${otherAccount.token}`,
        },
        body: '{"maximum_audio_seconds":1}',
      }),
      null,
    );
    expect(served.status).toBe(201);
    expect((await served.json()).allowance).toMatchObject({
      used_seconds: 0,
      reserved_seconds: 1,
    });
    expect(
      store.access(store.authenticate(session.token, Date.now()), Date.now()),
    ).toMatchObject({
      used_seconds: 0,
      reserved_seconds: 0,
    });
    expect(
      (await service.handle(new Request("http://localhost/healthz"), null))
        .status,
    ).toBe(200);
    expect(
      (
        await service.handle(
          new Request("http://localhost/internal/status", {
            headers: { Authorization: `Bearer ${config.operatorToken}` },
          }),
          null,
        )
      ).status,
    ).toBe(200);
    for (const response of await Promise.all(pending)) {
      expect(response.status).toBe(408);
      expect(await response.json()).toEqual({
        error: { code: "request_timeout" },
      });
    }
    expect(
      (
        await service.handle(
          new Request("http://localhost/v1/access", {
            headers: { Authorization: `Bearer ${session.token}` },
          }),
          null,
        )
      ).status,
    ).toBe(200);
  } finally {
    abort.abort();
    await Promise.all(pending);
  }
});

test.each([false, true])(
  "header and first audio deadline charges the minimum and releases idle hold; dispatched=%s",
  async (dispatched) => {
    let upstreamCalls = 0;
    const started = Promise.withResolvers<void>();
    const { service, session, store, config } = await setup(async (request) => {
      upstreamCalls++;
      const reader = request.body?.getReader();
      if (!reader) throw new Error("Missing upload body");
      try {
        await reader.read();
        started.resolve();
        while (!(await reader.read()).done) {}
      } catch {
      } finally {
        reader.releaseLock();
      }
      return Response.json({ combinedPhrases: [{ text: "unused" }] });
    });
    const grant = store.reserve(
      store.authenticate(session.token, Date.now()),
      10,
      Date.now(),
    );
    const input = multipart(wav(0, true));
    const abort = new AbortController();
    const responsePromise = service.handle(
      new Request(
        `http://localhost${transcriptionPath}?api-version=2025-10-15`,
        {
          method: "POST",
          signal: AbortSignal.any([abort.signal, AbortSignal.timeout(4500)]),
          headers: {
            Authorization: `Bearer ${grant.token}`,
            "Content-Type": input.contentType,
          },
          body: new ReadableStream({
            start(controller) {
              if (dispatched)
                controller.enqueue(
                  input.bytes.subarray(
                    0,
                    input.bytes.indexOf(Buffer.from("RIFF")) + 44,
                  ),
                );
            },
          }),
        },
      ),
      null,
    );
    const status = () =>
      service.handle(
        new Request("http://localhost/internal/status", {
          headers: { Authorization: `Bearer ${config.operatorToken}` },
        }),
        null,
      );
    try {
      if (dispatched)
        await Promise.race([
          started.promise,
          responsePromise.then(() => {
            throw new Error("Upload ended before dispatch");
          }),
        ]);
      expect((await (await status()).json()).active).toBe(dispatched ? 1 : 0);
      if (dispatched)
        expect(
          (
            await service.handle(
              new Request("http://localhost/internal/fence", {
                method: "POST",
                headers: { Authorization: `Bearer ${config.operatorToken}` },
              }),
              null,
            )
          ).status,
        ).toBe(409);
      const response = await responsePromise;
      expect(response.status).toBe(408);
      expect(await response.json()).toEqual({
        error: { code: "upload_header_timeout" },
      });
      expect(upstreamCalls).toBe(dispatched ? 1 : 0);
      expect(
        store.access(store.authenticate(session.token, Date.now()), Date.now()),
      ).toMatchObject({
        used_seconds: 1,
        reserved_seconds: 0,
      });
      expect((await (await status()).json()).active).toBe(0);
      expect(
        (
          await service.handle(
            new Request("http://localhost/internal/fence", {
              method: "POST",
              headers: { Authorization: `Bearer ${config.operatorToken}` },
            }),
            null,
          )
        ).status,
      ).toBe(200);
    } finally {
      abort.abort();
      await responsePromise;
    }
  },
);

test.each(["silence", "preamble", "partial header"])(
  "repeated undispatched %s claims never hold the idle fence or spend allowance",
  async (kind) => {
    let upstreamCalls = 0;
    const { call, service, session, store, config } = await setup(async () => {
      upstreamCalls++;
      return new Response();
    });
    const input = multipart(wav(0, true));
    const audioAt = input.bytes.indexOf(Buffer.from("RIFF"));
    const length =
      kind === "silence" ? 0 : audioAt + (kind === "preamble" ? 0 : 43);
    for (let cycle = 0; cycle < 3; cycle++) {
      const abort = new AbortController();
      let canceled = 0;
      const pending = Array.from({ length: 2 }, () => {
        const grant = store.reserve(
          store.authenticate(session.token, Date.now()),
          10,
          Date.now(),
        );
        return service.handle(
          new Request(
            `http://localhost${transcriptionPath}?api-version=2025-10-15`,
            {
              method: "POST",
              signal: AbortSignal.any([
                abort.signal,
                AbortSignal.timeout(2500),
              ]),
              headers: {
                Authorization: `Bearer ${grant.token}`,
                "Content-Type": input.contentType,
              },
              body: new ReadableStream({
                start(controller) {
                  if (length)
                    controller.enqueue(input.bytes.subarray(0, length));
                },
                cancel() {
                  canceled++;
                },
              }),
            },
          ),
          null,
        );
      });
      try {
        const status = await (
          await call("/internal/status", "GET", config.operatorToken)
        ).json();
        expect(status.active).toBe(0);
        expect(
          (await call("/internal/fence", "POST", config.operatorToken)).status,
        ).toBe(200);
        for (const response of await Promise.all(pending)) {
          expect(response.status).toBe(503);
          expect(await response.json()).toEqual({
            error: { code: "service_unavailable" },
          });
        }
        expect(canceled).toBe(2);
        expect(upstreamCalls).toBe(0);
        expect(
          store.access(
            store.authenticate(session.token, Date.now()),
            Date.now(),
          ),
        ).toMatchObject({ used_seconds: 0, reserved_seconds: 0 });
        expect(
          (await call("/internal/reopen", "POST", config.operatorToken)).status,
        ).toBe(200);
      } finally {
        abort.abort();
        await Promise.all(pending);
      }
    }
  },
);

test("rate limit counts each origin alone, with no shared budget, and limits IPv6 per /64 and /48", async () => {
  const { service } = await setup(async () => new Response());
  const enroll = (ip: string | null) =>
    service.handle(
      new Request("http://localhost/v1/sessions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: '{"web_auth_token":"apple-proof"}',
      }),
      ip,
    );
  for (let count = 0; count < 9; count++)
    expect((await enroll("192.0.2.1")).status).toBe(201);
  for (let count = 0; count < 3; count++) {
    const response = await enroll("192.0.2.1");
    expect(response.status).toBe(429);
    expect(await response.json()).toEqual({
      error: { code: "enrollment_rate_limited" },
    });
  }
  expect((await enroll("::ffff:192.0.2.1")).status).toBe(429);
  expect((await enroll("0:0:0:0:0:ffff:c000:201")).status).toBe(429);
  for (let origin = 2; origin < 15; origin++)
    for (let count = 0; count < 10; count++)
      expect((await enroll(`::ffff:192.0.2.${origin}`)).status).toBe(201);
  for (let count = 0; count < 10; count++)
    expect((await enroll(`2001:db8:1234:5678::${count + 1}`)).status).toBe(201);
  expect((await enroll("2001:0db8:1234:5678:ffff:ffff:ffff:ffff")).status).toBe(
    429,
  );
  for (let count = 0; count < 90; count++)
    expect((await enroll(`2001:db8:1234:${count + 1}::1`)).status).toBe(201);
  expect((await enroll("2001:db8:1234:ffff::1")).status).toBe(429);
  expect((await enroll("2001:db8:1235::1")).status).toBe(201);
});

test("a full origin table forgets its oldest origin instead of refusing new ones", async () => {
  const { service } = await setup(async () => new Response());
  const junk = (ip: string) =>
    service.handle(
      new Request("http://localhost/v1/sessions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "{}",
      }),
      ip,
    );
  for (let origin = 0; origin < 10_000; origin++)
    expect(
      (await junk(`10.${origin >> 16}.${(origin >> 8) & 255}.${origin & 255}`))
        .status,
    ).toBe(400);
  const response = await service.handle(
    new Request("http://localhost/v1/sessions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: '{"web_auth_token":"apple-proof"}',
    }),
    "198.51.100.7",
  );
  expect(response.status).toBe(201);
});

test("missing or invalid enrollment IP refuses only that request and rate-limits diagnostics", async () => {
  let fatal = false;
  const { service, session } = await setup(
    async () => new Response(),
    () => {
      fatal = true;
    },
  );
  const log = spyOn(console, "error").mockImplementation(() => {});
  try {
    for (const ip of [null, "invalid", "::1%lo0"]) {
      const response = await service.handle(
        new Request("http://localhost/v1/sessions", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: '{"web_auth_token":"apple-proof"}',
        }),
        ip,
      );
      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({
        error: { code: "service_unavailable" },
      });
    }
    expect(log).toHaveBeenCalledTimes(1);
    expect(log.mock.calls[0]?.[0]).toBe(
      JSON.stringify({
        event: "access_service_incident",
        code: "client_ip_unavailable",
      }),
    );
    expect(fatal).toBe(false);
    expect(
      (await service.handle(new Request("http://localhost/healthz"), null))
        .status,
    ).toBe(200);
    expect(
      (
        await service.handle(
          new Request("http://localhost/v1/access", {
            headers: { Authorization: `Bearer ${session.token}` },
          }),
          null,
        )
      ).status,
    ).toBe(200);
  } finally {
    log.mockRestore();
  }
});

test.each([
  "invalid JSON",
  "duplicate key",
  "high-bit magic",
  "epilogue",
  "split epilogue",
  "extra batch bytes",
])("input validation rejects %s at its owning boundary", async (kind) => {
  let input = multipart(wav(100));
  if (kind === "invalid JSON" || kind === "duplicate key") {
    const text =
      kind === "invalid JSON"
        ? "{"
        : '{"enhancedMode":{"enabled":true,"model":"MAI-Transcribe-2","modelOptions":{"transcribeStyle":"clean","transcribeStyle":"clean"}}}';
    input = {
      ...input,
      bytes: Buffer.from(
        input.bytes.toString().replace(JSON.stringify(options), text),
      ),
    };
  }
  if (kind === "high-bit magic") {
    const audio = wav(100);
    audio[0] = 0xd2;
    input = multipart(audio);
  }
  if (kind === "epilogue" || kind === "split epilogue")
    input = multipart(
      wav(100),
      options,
      "ignored\r\n--synthetic-boundary--\r\n",
    );
  if (kind === "extra batch bytes")
    input = multipart(Buffer.concat([wav(100), Buffer.alloc(1000)]));
  const upload = new TranscriptionUpload(
    new Request("http://localhost", {
      method: "POST",
      headers: { "Content-Type": input.contentType },
      body:
        kind === "split epilogue"
          ? new ReadableStream({
              start(controller) {
                for (const byte of input.bytes)
                  controller.enqueue(Uint8Array.of(byte));
                controller.close();
              },
            })
          : input.bytes,
    }),
    160_000,
    AbortSignal.timeout(2000),
  );
  let forwarded = Buffer.alloc(0);
  const operation = async () => {
    const prepared = await upload.prepare(() => {});
    const reader = prepared.body.getReader();
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      forwarded = Buffer.concat([forwarded, next.value]);
    }
  };
  const code =
    kind === "invalid JSON"
      ? "invalid_json"
      : kind === "duplicate key"
        ? "duplicate_json_key"
        : kind.includes("epilogue")
          ? "invalid_multipart"
          : "invalid_audio";
  try {
    await expect(operation()).rejects.toMatchObject({ status: 400, code });
    if (kind === "extra batch bytes") {
      expect(upload.samples).toBe(100);
      const audioAt = forwarded.indexOf(Buffer.from("RIFF"));
      expect(forwarded.length - audioAt).toBe(244);
    }
  } finally {
    await upload.close();
  }
});

test.each([0, 16_000])(
  "client cancellation with %s supplied samples settles measured audio once",
  async (samples) => {
    const received = Promise.withResolvers<void>();
    const { service, store, session } = await setup(async (request) => {
      const reader = request.body?.getReader();
      if (!reader) throw new Error("Missing body");
      let wire = Buffer.alloc(0);
      while (true) {
        const next = await reader.read();
        if (next.done) break;
        wire = Buffer.concat([wire, next.value]);
        const audioAt = wire.indexOf(Buffer.from("RIFF"));
        if (audioAt >= 0 && wire.length >= audioAt + 44 + (samples > 0 ? 2 : 0))
          received.resolve();
      }
      return Response.json({ combinedPhrases: [{ text: "unused" }] });
    });
    const grant = store.reserve(
      store.authenticate(session.token, Date.now()),
      10,
      Date.now(),
    );
    const abort = new AbortController();
    const input = multipart(wav(samples, true));
    const pending = service.handle(
      new Request(
        `http://localhost${transcriptionPath}?api-version=2025-10-15`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${grant.token}`,
            "Content-Type": input.contentType,
          },
          signal: abort.signal,
          body: new ReadableStream({
            start(controller) {
              controller.enqueue(
                input.bytes.subarray(
                  0,
                  samples === 0
                    ? input.bytes.indexOf(Buffer.from("RIFF")) + 44
                    : input.bytes.length - 30,
                ),
              );
            },
          }),
        },
      ),
      "192.0.2.1",
    );
    await received.promise;
    abort.abort();
    expect((await pending).status).toBe(502);
    expect(
      store.access(store.authenticate(session.token, Date.now()), Date.now()),
    ).toMatchObject({
      used_seconds: 1,
      reserved_seconds: 0,
    });
    expect(() => store.claim(grant.token, Date.now())).toThrow("invalid_grant");
  },
);

test.each([
  " X\r\nignored\r\n--synthetic-boundary--\r\n",
  "X\r\nignored\r\n--synthetic-boundary--\r\n",
  "\r\nepilogue\r\n--synthetic-boundary--\r\n",
  "",
])(
  "the first closing delimiter requires CRLF then EOF (%j)",
  async (ending) => {
    const { service, store, session } = await setup(async (request) => {
      await request.arrayBuffer();
      return Response.json({
        combinedPhrases: [{ text: "unexpected result" }],
      });
    });
    const grant = store.reserve(
      store.authenticate(session.token, Date.now()),
      10,
      Date.now(),
    );
    const input = multipart(wav(100));
    const bytes = Buffer.concat([
      input.bytes.subarray(0, input.bytes.length - 2),
      Buffer.from(ending),
    ]);
    const response = await service.handle(
      new Request(
        `http://localhost${transcriptionPath}?api-version=2025-10-15`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${grant.token}`,
            "Content-Type": input.contentType,
          },
          body: new ReadableStream({
            start(controller) {
              for (const byte of bytes) controller.enqueue(Uint8Array.of(byte));
              controller.close();
            },
          }),
        },
      ),
      null,
    );
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({
      error: { code: "invalid_multipart" },
    });
    expect(
      store.access(store.authenticate(session.token, Date.now()), Date.now())
        .reserved_seconds,
    ).toBe(0);
  },
);

test("wrong preamble is rejected on its first byte before dispatch or EOF", async () => {
  let calls = 0;
  const { service, session, store } = await setup(async () => {
    calls++;
    return new Response();
  });
  const grant = store.reserve(
    store.authenticate(session.token, Date.now()),
    10,
    Date.now(),
  );
  const response = await service.handle(
    new Request(`http://localhost${transcriptionPath}?api-version=2025-10-15`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${grant.token}`,
        "Content-Type": "multipart/form-data; boundary=synthetic-boundary",
      },
      body: new ReadableStream({
        start(controller) {
          controller.enqueue(Uint8Array.of(0x58));
        },
      }),
    }),
    null,
  );
  expect(response.status).toBe(400);
  expect(await response.json()).toEqual({
    error: { code: "invalid_multipart" },
  });
  expect(calls).toBe(0);
  expect(
    store.access(store.authenticate(session.token, Date.now()), Date.now()),
  ).toMatchObject({
    used_seconds: 1,
    reserved_seconds: 0,
  });
});

test("response-read cancellation retains client-failure charging", async () => {
  const { service, store, session } = await setup(async () => new Response());
  const originalFetch = globalThis.fetch;
  const readingResponse = Promise.withResolvers<void>();
  let emitted = false;
  const fetchSpy = spyOn(globalThis, "fetch").mockImplementation(
    Object.assign(
      async (
        _input: Parameters<typeof fetch>[0],
        init?: Parameters<typeof fetch>[1],
      ) => {
        await new Response(init?.body).arrayBuffer();
        return new Response(
          new ReadableStream(
            {
              pull(controller) {
                if (!emitted) {
                  emitted = true;
                  controller.enqueue(
                    new TextEncoder().encode('{"combinedPhrases":['),
                  );
                  readingResponse.resolve();
                }
              },
            },
            { highWaterMark: 0 },
          ),
        );
      },
      { preconnect: originalFetch.preconnect },
    ),
  );
  const grant = store.reserve(
    store.authenticate(session.token, Date.now()),
    10,
    Date.now(),
  );
  const abort = new AbortController();
  const input = multipart(wav(16_000));
  const pending = service.handle(
    new Request(`http://localhost${transcriptionPath}?api-version=2025-10-15`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${grant.token}`,
        "Content-Type": input.contentType,
      },
      body: input.bytes,
      signal: AbortSignal.any([abort.signal, AbortSignal.timeout(3500)]),
    }),
    null,
  );
  try {
    await Promise.race([
      readingResponse.promise,
      pending.then(() => {
        throw new Error("Upload ended before response reading");
      }),
    ]);
    abort.abort();
    const response = await pending;
    expect(response.status).toBe(408);
    expect(await response.json()).toEqual({
      error: { code: "request_timeout" },
    });
    expect(
      store.access(store.authenticate(session.token, Date.now()), Date.now()),
    ).toMatchObject({
      used_seconds: 1,
      reserved_seconds: 0,
    });
  } finally {
    abort.abort();
    await pending;
    fetchSpy.mockRestore();
  }
});

test.each([1, 48_000])(
  "upload progress floor accounts for %s initial samples and releases its idle hold",
  async (initialSamples) => {
    const received = Promise.withResolvers<void>();
    const { service, store, session, config } = await setup(async (request) => {
      try {
        const reader = request.body?.getReader();
        if (!reader) throw new Error("Missing body");
        let wire = Buffer.alloc(0);
        while (true) {
          const next = await reader.read();
          if (next.done) break;
          wire = Buffer.concat([wire, next.value]);
          const audioAt = wire.indexOf(Buffer.from("RIFF"));
          if (audioAt >= 0 && wire.length >= audioAt + 44 + initialSamples * 2)
            received.resolve();
        }
      } catch {}
      return Response.json({
        combinedPhrases: [{ text: "Synthetic result." }],
      });
    });
    const grant = store.reserve(
      store.authenticate(session.token, Date.now()),
      10,
      Date.now(),
    );
    const input = multipart(wav(initialSamples, true));
    const splitAt =
      input.bytes.indexOf(Buffer.from("RIFF")) + 44 + initialSamples * 2;
    let bodyController: ReadableStreamDefaultController<Uint8Array> | undefined;
    const abort = new AbortController();
    let trickle: ReturnType<typeof setInterval> | undefined;
    const pending = service.handle(
      new Request(
        `http://localhost${transcriptionPath}?api-version=2025-10-15`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${grant.token}`,
            "Content-Type": input.contentType,
          },
          signal: AbortSignal.any([abort.signal, AbortSignal.timeout(18_000)]),
          body: new ReadableStream({
            start(controller) {
              bodyController = controller;
              controller.enqueue(input.bytes.subarray(0, splitAt));
            },
            cancel() {
              clearInterval(trickle);
            },
          }),
        },
      ),
      null,
    );
    try {
      await Promise.race([
        received.promise,
        pending.then(() => {
          throw new Error("Upload ended before forwarding audio");
        }),
      ]);
      if (initialSamples === 1)
        trickle = setInterval(
          () => bodyController?.enqueue(new Uint8Array(2)),
          100,
        );
      await new Promise((resolve) => setTimeout(resolve, 5000));
      const status = () =>
        service.handle(
          new Request("http://localhost/internal/status", {
            headers: { Authorization: `Bearer ${config.operatorToken}` },
          }),
          null,
        );
      expect((await (await status()).json()).active).toBe(1);
      if (initialSamples === 48_000) {
        await new Promise((resolve) => setTimeout(resolve, 6000));
        expect((await (await status()).json()).active).toBe(1);
        bodyController?.enqueue(input.bytes.subarray(splitAt));
        bodyController?.close();
      }
      const response = await pending;
      expect(response.status).toBe(initialSamples === 48_000 ? 200 : 408);
      expect(await response.json()).toEqual(
        initialSamples === 48_000
          ? { combinedPhrases: [{ text: "Synthetic result." }] }
          : { error: { code: "upload_too_slow" } },
      );
      expect(
        store.access(store.authenticate(session.token, Date.now()), Date.now()),
      ).toMatchObject({
        used_seconds: initialSamples === 1 ? 1 : 3,
        reserved_seconds: 0,
      });
      expect(
        (
          await service.handle(
            new Request("http://localhost/internal/fence", {
              method: "POST",
              headers: { Authorization: `Bearer ${config.operatorToken}` },
            }),
            null,
          )
        ).status,
      ).toBe(200);
    } finally {
      clearInterval(trickle);
      abort.abort();
      await pending;
    }
  },
  20_000,
);

test("stalled enrollments have separate bounded slots and cannot starve data or the idle fence", async () => {
  const { service, session, call, config } = await setup(
    async () => new Response(),
  );
  const abort = new AbortController();
  const pending = Array.from({ length: 64 }, (_, index) =>
    service.handle(
      new Request("http://localhost/v1/sessions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        signal: abort.signal,
        body: new ReadableStream(),
      }),
      `192.0.2.${index + 1}`,
    ),
  );
  try {
    expect((await call("/v1/access", "GET", session.token)).status).toBe(200);
    const status = await (
      await call("/internal/status", "GET", config.operatorToken)
    ).json();
    expect(status.active).toBe(0);
    expect(
      (await call("/internal/fence", "POST", config.operatorToken)).status,
    ).toBe(200);
    const responses = await Promise.all(pending);
    for (const [index, response] of responses.entries()) {
      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({
        error: {
          code: index < 8 ? "service_unavailable" : "service_busy",
        },
      });
    }
    expect(
      (await call("/internal/reopen", "POST", config.operatorToken)).status,
    ).toBe(200);
    const expired = await service.handle(
      new Request("http://localhost/v1/sessions", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: new ReadableStream(),
      }),
      "192.0.2.100",
    );
    expect(expired.status).toBe(408);
    expect(await expired.json()).toEqual({
      error: { code: "request_timeout" },
    });
    expect(
      (
        await call("/v1/sessions", "POST", undefined, {
          web_auth_token: "apple-proof",
        })
      ).status,
    ).toBe(201);
  } finally {
    abort.abort();
    await Promise.all(pending);
  }
});

test("a ready client is not timed out or charged while the upstream stops consuming", async () => {
  const { service, store, session, config } = await setup(
    async () => new Response(),
  );
  const originalFetch = globalThis.fetch;
  const blocked = Promise.withResolvers<void>();
  const resume = Promise.withResolvers<void>();
  const fetchSpy = spyOn(globalThis, "fetch").mockImplementation(
    Object.assign(
      async (
        _input: Parameters<typeof fetch>[0],
        init?: Parameters<typeof fetch>[1],
      ) => {
        const reader = new Response(init?.body).body?.getReader();
        if (!reader) throw new Error("Missing upstream body");
        let wire = Buffer.alloc(0);
        while (
          wire.indexOf(Buffer.from("RIFF")) < 0 ||
          wire.length <= wire.indexOf(Buffer.from("RIFF")) + 44
        ) {
          const next = await reader.read();
          if (next.done) throw new Error("Upload ended before audio");
          wire = Buffer.concat([wire, next.value]);
        }
        blocked.resolve();
        await resume.promise;
        while (!(await reader.read()).done) {}
        return Response.json({
          combinedPhrases: [{ text: "Synthetic result." }],
        });
      },
      { preconnect: originalFetch.preconnect },
    ),
  );
  let now = 1000;
  const clock = spyOn(performance, "now").mockImplementation(() => now);
  const grant = store.reserve(
    store.authenticate(session.token, Date.now()),
    30,
    Date.now(),
  );
  const input = multipart(wav(320_000));
  const abort = new AbortController();
  const pending = service.handle(
    new Request(`http://localhost${transcriptionPath}?api-version=2025-10-15`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${grant.token}`,
        "Content-Type": input.contentType,
      },
      signal: AbortSignal.any([abort.signal, AbortSignal.timeout(3500)]),
      body: new ReadableStream({
        start(controller) {
          for (let at = 0; at < input.bytes.length; at += 32_000)
            controller.enqueue(input.bytes.subarray(at, at + 32_000));
          controller.close();
        },
      }),
    }),
    null,
  );
  try {
    await Promise.race([
      blocked.promise,
      pending.then(() => {
        throw new Error("Upload ended before upstream stalled");
      }),
    ]);
    now += 20_000;
    await new Promise((resolve) => setTimeout(resolve, 1100));
    const status = await service.handle(
      new Request("http://localhost/internal/status", {
        headers: { Authorization: `Bearer ${config.operatorToken}` },
      }),
      null,
    );
    expect((await status.json()).active).toBe(1);
    expect(
      store.access(store.authenticate(session.token, Date.now()), Date.now()),
    ).toMatchObject({ used_seconds: 0, reserved_seconds: 30 });
    resume.resolve();
    const response = await pending;
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      combinedPhrases: [{ text: "Synthetic result." }],
    });
    expect(
      store.access(store.authenticate(session.token, Date.now()), Date.now()),
    ).toMatchObject({ used_seconds: 20, reserved_seconds: 0 });
  } finally {
    resume.resolve();
    abort.abort();
    await pending;
    fetchSpy.mockRestore();
    clock.mockRestore();
  }
});
