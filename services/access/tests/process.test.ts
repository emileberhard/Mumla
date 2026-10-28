import { Database } from "bun:sqlite";
import { expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AccessConfig } from "../src/config";
import { transcriptionPath } from "../src/protocol";
import { AccessStore } from "../src/store";

const main = new URL("../src/main.ts", import.meta.url).pathname;
const preload = new URL("fixtures/cloudkit-preload.ts", import.meta.url)
  .pathname;

async function fixture(upstream: (request: Request) => Promise<Response>) {
  const directory = mkdtempSync(join(tmpdir(), "mumla-process-test-"));
  const router = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request) {
      if (new URL(request.url).pathname === "/health")
        return Response.json({ service: "llm-router", status: "ok" });
      return upstream(request);
    },
  });
  const listener = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch: () => new Response(),
  });
  const port = listener.port;
  await listener.stop(true);
  if (!port) throw new Error("Missing port");
  const config: AccessConfig = {
    listenPort: port,
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
  const session = store.enroll("synthetic-account", Date.now());
  store.close();
  const configPath = join(directory, "config.json");
  await Bun.write(configPath, JSON.stringify(config));
  const processes: ReturnType<typeof Bun.spawn>[] = [];
  const start = async () => {
    const child = Bun.spawn(
      [
        process.execPath,
        "--preload",
        preload,
        main,
        "serve",
        "--config",
        configPath,
      ],
      { stdout: "pipe", stderr: "pipe" },
    );
    processes.push(child);
    const stderr = new Response(child.stderr).text();
    const reader = child.stdout.getReader();
    const started = await reader.read();
    reader.releaseLock();
    expect(new TextDecoder().decode(started.value)).toContain(
      "access_service_started",
    );
    return { child, stderr };
  };
  const call = (
    path: string,
    method = "GET",
    body?: unknown,
    token = session.token,
  ) =>
    fetch(`http://127.0.0.1:${port}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        "CF-Connecting-IP": "192.0.2.1",
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
  const open = () =>
    call("/internal/reopen", "POST", undefined, config.operatorToken);
  return {
    config,
    session,
    start,
    call,
    open,
    async close() {
      for (const child of processes) {
        if (child.exitCode === null) child.kill("SIGKILL");
        await child.exited;
      }
      await router.stop(true);
      rmSync(directory, { recursive: true, force: true });
    },
  };
}

test("SIGKILL during a real upload releases its durable hold on process restart", async () => {
  const dispatched = Promise.withResolvers<void>();
  const state = await fixture(async (request) => {
    try {
      const reader = request.body?.getReader();
      if (!reader) throw new Error("Missing body");
      let wire = Buffer.alloc(0);
      while (true) {
        const next = await reader.read();
        if (next.done) break;
        wire = Buffer.concat([wire, next.value]);
        const audioAt = wire.indexOf(Buffer.from("RIFF"));
        if (audioAt >= 0 && wire.length >= audioAt + 46) dispatched.resolve();
      }
    } catch {}
    return new Response(null, { status: 500 });
  });
  try {
    const first = await state.start();
    expect((await state.open()).status).toBe(200);
    const grant = await (
      await state.call("/v1/dictations", "POST", { maximum_audio_seconds: 10 })
    ).json();
    const fixtureRoot = new URL("fixtures/", import.meta.url);
    const input = await Bun.file(
      new URL("speechkit-progressive.bin", fixtureRoot),
    ).bytes();
    const abort = new AbortController();
    const pending = fetch(
      `http://127.0.0.1:${state.config.listenPort}${transcriptionPath}?api-version=2025-10-15`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${grant.token}`,
          "CF-Connecting-IP": "192.0.2.1",
          "Content-Type": (
            await Bun.file(
              new URL("speechkit-content-type.txt", fixtureRoot),
            ).text()
          ).trim(),
        },
        signal: abort.signal,
        body: new ReadableStream({
          start(controller) {
            controller.enqueue(input.subarray(0, input.length - 50));
          },
        }),
      },
    ).catch(() => undefined);
    await dispatched.promise;
    first.child.kill("SIGKILL");
    expect(await first.child.exited).not.toBe(0);
    abort.abort();
    await pending;
    const restarted = await state.start();
    expect((await state.open()).status).toBe(200);
    expect(
      (await (await state.call("/v1/access")).json()).allowance,
    ).toMatchObject({ used_seconds: 0, reserved_seconds: 0 });
    expect(
      (
        await state.call(
          "/internal/fence",
          "POST",
          undefined,
          state.config.operatorToken,
        )
      ).status,
    ).toBe(200);
    restarted.child.kill("SIGTERM");
    expect(await restarted.child.exited).toBe(0);
    expect(await restarted.stderr).toContain(
      '"code":"recovered_reservations","count":1',
    );
  } finally {
    await state.close();
  }
});

test("failed settlement COMMIT fences, exits nonzero and recovers without a stuck active upload", async () => {
  const state = await fixture(async (request) => {
    await request.arrayBuffer();
    return Response.json({ combinedPhrases: [{ text: "Synthetic result." }] });
  });
  try {
    const db = new Database(state.config.database);
    db.exec(`
      CREATE TABLE settlement_fault (parent TEXT REFERENCES subjects(id) DEFERRABLE INITIALLY DEFERRED) STRICT;
      CREATE TRIGGER fail_settlement AFTER INSERT ON usage BEGIN
        INSERT INTO settlement_fault VALUES ('absent-subject');
      END;
    `);
    db.close();
    const running = await state.start();
    expect((await state.open()).status).toBe(200);
    const grant = await (
      await state.call("/v1/dictations", "POST", { maximum_audio_seconds: 10 })
    ).json();
    const fixtureRoot = new URL("fixtures/", import.meta.url);
    const response = await fetch(
      `http://127.0.0.1:${state.config.listenPort}${transcriptionPath}?api-version=2025-10-15`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${grant.token}`,
          "CF-Connecting-IP": "192.0.2.1",
          "Content-Type": (
            await Bun.file(
              new URL("speechkit-content-type.txt", fixtureRoot),
            ).text()
          ).trim(),
        },
        body: Bun.file(new URL("speechkit-progressive.bin", fixtureRoot)),
      },
    );
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({
      error: { code: "service_unavailable" },
    });
    expect(await running.child.exited).toBe(1);
    const log = await running.stderr;
    expect(log).toContain('"code":"unexpected_failure"');
    expect(log).toContain('"sqlite_code":"SQLITE_CONSTRAINT_FOREIGNKEY"');
    const repair = new Database(state.config.database);
    repair.exec("DROP TRIGGER fail_settlement");
    repair.close();
    const recovered = await state.start();
    expect((await state.open()).status).toBe(200);
    expect(
      (await (await state.call("/v1/access")).json()).allowance,
    ).toMatchObject({ used_seconds: 0, reserved_seconds: 0 });
    expect(
      (
        await state.call(
          "/internal/fence",
          "POST",
          undefined,
          state.config.operatorToken,
        )
      ).status,
    ).toBe(200);
    recovered.child.kill("SIGTERM");
    expect(await recovered.child.exited).toBe(0);
    expect(await recovered.stderr).toContain(
      '"code":"recovered_reservations","count":1',
    );
  } finally {
    await state.close();
  }
});
