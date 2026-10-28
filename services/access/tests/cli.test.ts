import { expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { transcriptionPath } from "../src/protocol";

const main = new URL("../src/main.ts", import.meta.url).pathname;
const preload = new URL("fixtures/cloudkit-preload.ts", import.meta.url)
  .pathname;

test("CLI initializes explicitly, starts fenced, snapshots live state and checks it read-only", async () => {
  const directory = mkdtempSync(join(tmpdir(), "mumla-cli-test-"));
  const router = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(request) {
      if (new URL(request.url).pathname !== "/health") {
        await request.arrayBuffer();
        return Response.json({
          combinedPhrases: [{ text: "Synthetic result." }],
        });
      }
      return Response.json({ service: "llm-router", status: "ok" });
    },
  });
  const listener = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch() {
      return new Response();
    },
  });
  const port = listener.port;
  await listener.stop(true);
  const config = {
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
  const configPath = join(directory, "config.json");
  await Bun.write(configPath, JSON.stringify(config));
  const run = (operation: string, path: string) =>
    Bun.spawn(
      [
        process.execPath,
        "--preload",
        preload,
        main,
        operation,
        "--config",
        path,
      ],
      {
        stdout: "pipe",
        stderr: "pipe",
      },
    );
  let processHandle: ReturnType<typeof run> | undefined;
  try {
    const missing = run("serve", configPath);
    expect(await missing.exited).toBe(1);
    expect(await Bun.file(config.database).exists()).toBe(false);
    const initialize = run("init", configPath);
    expect(await initialize.exited).toBe(0);
    expect((await new Response(initialize.stdout).json()).initialized).toBe(
      true,
    );
    processHandle = run("serve", configPath);
    const reader = processHandle.stdout.getReader();
    const started = await reader.read();
    expect(new TextDecoder().decode(started.value)).toContain(
      "access_service_started",
    );
    reader.releaseLock();
    const url = `http://127.0.0.1:${port}`;
    const operator = (path: string) =>
      fetch(`${url}${path}`, {
        method: "POST",
        headers: { Authorization: `Bearer ${config.operatorToken}` },
      });
    expect((await fetch(`${url}/healthz`)).status).toBe(503);
    expect((await operator("/internal/reopen")).status).toBe(200);
    expect((await fetch(`${url}/healthz`)).status).toBe(200);
    const enroll = (headers: Record<string, string>, proof: string) =>
      fetch(`${url}/v1/sessions`, {
        method: "POST",
        headers: { ...headers, "Content-Type": "application/json" },
        body: JSON.stringify({ web_auth_token: proof }),
      });
    for (let index = 0; index < 2; index++) {
      const missingIP = await enroll(
        { "X-Real-IP": "192.0.2.1" },
        "apple-proof",
      );
      expect(missingIP.status).toBe(503);
      expect(await missingIP.json()).toEqual({
        error: { code: "service_unavailable" },
      });
      const deniedProof = await enroll(
        { "CF-Connecting-IP": "192.0.2.1" },
        "denied-proof",
      );
      expect(deniedProof.status).toBe(503);
      expect(await deniedProof.json()).toEqual({
        error: { code: "service_unavailable" },
      });
      const failedAPIProof = await enroll(
        { "CF-Connecting-IP": "192.0.2.1" },
        "failed-api-proof",
      );
      expect(failedAPIProof.status).toBe(503);
      expect(await failedAPIProof.json()).toEqual({
        error: { code: "service_unavailable" },
      });
    }
    const enrolled = await enroll(
      { "CF-Connecting-IP": "192.0.2.1" },
      "apple-proof",
    );
    expect(enrolled.status).toBe(201);
    const token = (await enrolled.json()).token;
    expect(
      (
        await fetch(`${url}/v1/access`, {
          headers: { Authorization: `Bearer ${token}` },
        })
      ).status,
    ).toBe(200);
    expect((await fetch(`${url}/healthz`)).status).toBe(200);
    const backup = await (await operator("/internal/backup")).json();
    const bytes = await Bun.file(`${config.database}.backup`).bytes();
    expect(new Bun.CryptoHasher("sha256").update(bytes).digest("hex")).toBe(
      backup.sha256,
    );
    expect((await operator("/internal/fence")).status).toBe(200);
    expect((await fetch(`${url}/healthz`)).status).toBe(503);
    processHandle.kill("SIGTERM");
    expect(await processHandle.exited).toBe(0);
    const incidents = await new Response(processHandle.stderr).text();
    expect(incidents.match(/"code":"client_ip_unavailable"/g)).toHaveLength(1);
    expect(incidents.match(/"code":"cloudkit_access_denied"/g)).toHaveLength(1);
    expect(
      incidents.match(/"code":"cloudkit_configuration_invalid"/g),
    ).toHaveLength(1);
    processHandle = undefined;
    const checkConfig = join(directory, "check.json");
    await Bun.write(
      checkConfig,
      JSON.stringify({ ...config, database: `${config.database}.backup` }),
    );
    const check = run("check", checkConfig);
    expect(await check.exited).toBe(0);
    expect(await new Response(check.stdout).json()).toEqual({
      version: "development",
      commit: "unreleased",
      ready: true,
      identity: "proven",
    });
    expect(await Bun.file(`${config.database}.backup`).bytes()).toEqual(bytes);
    const invalidConfig = join(directory, "invalid-api.json");
    await Bun.write(
      invalidConfig,
      JSON.stringify({
        ...config,
        database: `${config.database}.backup`,
        cloudKitAPIToken: "denied-api-token",
      }),
    );
    const invalid = run("check", invalidConfig);
    expect(await invalid.exited).toBe(1);
    expect(await new Response(invalid.stderr).text()).toContain(
      '"code":"cloudkit_access_denied"',
    );
    const transientConfig = join(directory, "transient-api.json");
    await Bun.write(
      transientConfig,
      JSON.stringify({ ...config, cloudKitAPIToken: "transient-api-token" }),
    );
    processHandle = run("serve", transientConfig);
    const running = processHandle.stdout.getReader();
    expect(new TextDecoder().decode((await running.read()).value)).toContain(
      "access_service_started",
    );
    running.releaseLock();
    expect((await operator("/internal/reopen")).status).toBe(200);
    const unavailable = await enroll(
      { "CF-Connecting-IP": "192.0.2.1" },
      "fresh-proof",
    );
    expect(unavailable.status).toBe(503);
    expect(await unavailable.json()).toEqual({
      error: { code: "identity_unavailable" },
    });
    expect(
      (
        await fetch(`${url}/v1/access`, {
          headers: { Authorization: `Bearer ${token}` },
        })
      ).status,
    ).toBe(200);
    const admitted = await fetch(`${url}/v1/dictations`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: '{"maximum_audio_seconds":1}',
    });
    expect(admitted.status).toBe(201);
    const grant = await admitted.json();
    const fixture = new URL("fixtures/", import.meta.url);
    const transcript = await fetch(
      `${url}${transcriptionPath}?api-version=2025-10-15`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${grant.token}`,
          "Content-Type": (
            await Bun.file(
              new URL("speechkit-content-type.txt", fixture),
            ).text()
          ).trim(),
        },
        body: await Bun.file(
          new URL("speechkit-progressive.bin", fixture),
        ).bytes(),
      },
    );
    expect(transcript.status).toBe(200);
    expect(await transcript.json()).toEqual({
      combinedPhrases: [{ text: "Synthetic result." }],
    });
    expect((await fetch(`${url}/healthz`)).status).toBe(200);
    expect((await operator("/internal/fence")).status).toBe(200);
    processHandle.kill("SIGTERM");
    expect(await processHandle.exited).toBe(0);
    processHandle = undefined;
    await Bun.write(
      transientConfig,
      JSON.stringify({
        ...config,
        database: `${config.database}.backup`,
        cloudKitAPIToken: "transient-api-token",
      }),
    );
    const degradedCheck = run("check", transientConfig);
    expect(await degradedCheck.exited).toBe(75);
    expect(await new Response(degradedCheck.stdout).json()).toMatchObject({
      ready: false,
      identity: "unproven",
    });
  } finally {
    if (processHandle) {
      processHandle.kill("SIGKILL");
      await processHandle.exited;
    }
    await router.stop(true);
    rmSync(directory, { recursive: true, force: true });
  }
});
