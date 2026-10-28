import { afterEach, expect, spyOn, test } from "bun:test";
import { CloudKitIdentity } from "../src/cloudkit";

const originalFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = originalFetch;
});

test("only Apple's returned record name selects identity; query tokens are encoded", async () => {
  let recordName = "apple-record-a";
  let calls = 0;
  spyOn(globalThis, "fetch").mockImplementation(
    Object.assign(
      async (
        input: Parameters<typeof fetch>[0],
        options: Parameters<typeof fetch>[1],
      ) => {
        const url = new URL(input as URL);
        expect(url.origin).toBe("https://api.apple-cloudkit.com");
        expect(url.pathname).toBe(
          "/database/1/iCloud.example.synthetic/production/public/users/caller",
        );
        if (!url.searchParams.has("ckWebAuthToken"))
          return Response.json(
            { serverErrorCode: "AUTHENTICATION_REQUIRED" },
            { status: 421 },
          );
        expect(url.searchParams.get("ckWebAuthToken")).toBe("proof+/=");
        expect(url.searchParams.get("ckAPIToken")).toBe("synthetic-api-token");
        expect(options?.redirect).toBe("error");
        calls++;
        return Response.json({
          userRecordName: recordName,
          firstName: `ignored-${calls}`,
          ckWebAuthToken: "discarded-replacement",
        });
      },
      { preconnect: originalFetch.preconnect },
    ),
  );
  const verifier = new CloudKitIdentity(
    "iCloud.example.synthetic",
    "synthetic-api-token",
  );
  const first = await verifier.verify("proof+/=", AbortSignal.timeout(500));
  expect(await verifier.verify("proof+/=", AbortSignal.timeout(500))).toBe(
    first,
  );
  recordName = "apple-record-b";
  expect(await verifier.verify("proof+/=", AbortSignal.timeout(500))).not.toBe(
    first,
  );
});

test.each([
  [401, { serverErrorCode: "AUTHENTICATION_FAILED" }, "service_unavailable"],
  [421, { serverErrorCode: "AUTHENTICATION_REQUIRED" }, "invalid_identity"],
  [403, { serverErrorCode: "ACCESS_DENIED" }, "service_unavailable"],
  [200, { serverErrorCode: "ACCESS_DENIED" }, "service_unavailable"],
  [503, {}, "identity_unavailable"],
  [200, {}, "identity_unavailable"],
  [200, { userRecordName: "" }, "identity_unavailable"],
  [200, { users: [{ userRecordName: "a" }] }, "identity_unavailable"],
])(
  "fails closed on Apple status %s and ambiguous identity",
  async (status, body, code) => {
    mockProofResponse(() => Response.json(body, { status }));
    await expect(
      new CloudKitIdentity("iCloud.example.synthetic", "api-token").verify(
        "proof",
        AbortSignal.timeout(500),
      ),
    ).rejects.toThrow(code);
  },
);

test("duplicate Apple identity keys fail closed", async () => {
  mockProofResponse(
    () => new Response('{"userRecordName":"a","userRecordName":"b"}'),
  );
  await expect(
    new CloudKitIdentity("iCloud.example.synthetic", "api-token").verify(
      "proof",
      AbortSignal.timeout(500),
    ),
  ).rejects.toThrow("identity_unavailable");
});

test.each([
  [421, { serverErrorCode: "AUTHENTICATION_REQUIRED" }, true],
  [403, { serverErrorCode: "ACCESS_DENIED" }, false],
  [401, { serverErrorCode: "AUTHENTICATION_FAILED" }, false],
  [400, { serverErrorCode: "BAD_REQUEST" }, false],
  [404, { serverErrorCode: "NOT_FOUND" }, false],
  [400, "unexpected body", false],
  [404, "unexpected body", false],
  [200, { userRecordName: "unexpected-user" }, false],
  [200, "unexpected body", false],
])(
  "startup validates the API token without a user proof at status %s",
  async (status, body, ready) => {
    spyOn(globalThis, "fetch").mockImplementation(
      Object.assign(
        async (input: Parameters<typeof fetch>[0]) => {
          const url = new URL(
            input instanceof Request ? input.url : input.toString(),
          );
          expect(url.searchParams.get("ckAPIToken")).toBe(
            "synthetic-api-token",
          );
          expect(url.searchParams.has("ckWebAuthToken")).toBe(false);
          return Response.json(body, { status });
        },
        { preconnect: originalFetch.preconnect },
      ),
    );
    const check = new CloudKitIdentity(
      "iCloud.example.synthetic",
      "synthetic-api-token",
    ).check();
    if (ready) await expect(check).resolves.toBe(true);
    else
      await expect(check).rejects.toThrow(
        status === 403
          ? "cloudkit_access_denied"
          : "cloudkit_configuration_invalid",
      );
  },
);

function mockProofResponse(response: () => Response) {
  spyOn(globalThis, "fetch").mockImplementation(
    Object.assign(
      async (input: Parameters<typeof fetch>[0]) => {
        const url = new URL(
          input instanceof Request ? input.url : input.toString(),
        );
        return url.searchParams.has("ckWebAuthToken")
          ? response()
          : Response.json(
              { serverErrorCode: "AUTHENTICATION_REQUIRED" },
              { status: 421 },
            );
      },
      { preconnect: originalFetch.preconnect },
    ),
  );
}

test.each(["network", "timeout", "server"])(
  "transient %s API proof failure gates enrollment and retries with backoff",
  async (failure) => {
    let now = Date.now();
    const clock = spyOn(Date, "now").mockImplementation(() => now);
    const log = spyOn(console, "error").mockImplementation(() => {});
    let recovered = false;
    let probes = 0;
    const fetchSpy = spyOn(globalThis, "fetch").mockImplementation(
      Object.assign(
        async (input: Parameters<typeof fetch>[0]) => {
          const url = new URL(
            input instanceof Request ? input.url : input.toString(),
          );
          if (url.searchParams.has("ckWebAuthToken"))
            return Response.json({ userRecordName: "synthetic-account" });
          probes++;
          if (!recovered) {
            if (failure === "network")
              throw new TypeError("synthetic DNS failure");
            if (failure === "timeout")
              throw new DOMException("synthetic timeout", "TimeoutError");
            return Response.json(
              { serverErrorCode: "TRY_AGAIN_LATER" },
              { status: 503 },
            );
          }
          return Response.json(
            { serverErrorCode: "AUTHENTICATION_REQUIRED" },
            { status: 421 },
          );
        },
        { preconnect: originalFetch.preconnect },
      ),
    );
    try {
      const verifier = new CloudKitIdentity(
        "iCloud.example.synthetic",
        "api-token",
      );
      await expect(verifier.check()).resolves.toBe(false);
      await expect(
        verifier.verify("unused-proof", AbortSignal.timeout(500)),
      ).rejects.toMatchObject({
        status: 503,
        code: "identity_unavailable",
      });
      expect(probes).toBe(1);
      now += 2000;
      await expect(
        verifier.verify("another-unused-proof", AbortSignal.timeout(500)),
      ).rejects.toMatchObject({ status: 503, code: "identity_unavailable" });
      expect(probes).toBe(2);
      await expect(verifier.check()).resolves.toBe(false);
      expect(probes).toBe(2);
      recovered = true;
      now += 3000;
      expect(
        await verifier.verify("fresh-proof", AbortSignal.timeout(500)),
      ).toMatch(/^[0-9a-f]{64}$/);
      expect(probes).toBe(3);
      expect(log).toHaveBeenCalledTimes(1);
    } finally {
      fetchSpy.mockRestore();
      log.mockRestore();
      clock.mockRestore();
    }
  },
);

test("canceling enrollment aborts the in-flight CloudKit proof exchange", async () => {
  const started = Promise.withResolvers<void>();
  const response = Promise.withResolvers<Response>();
  let upstreamSignal: AbortSignal | null | undefined;
  const fetchSpy = spyOn(globalThis, "fetch").mockImplementation(
    Object.assign(
      async (
        input: Parameters<typeof fetch>[0],
        init?: Parameters<typeof fetch>[1],
      ) => {
        const url = new URL(
          input instanceof Request ? input.url : input.toString(),
        );
        if (!url.searchParams.has("ckWebAuthToken"))
          return Response.json(
            { serverErrorCode: "AUTHENTICATION_REQUIRED" },
            { status: 421 },
          );
        const signal = init?.signal;
        if (!signal) throw new Error("Missing cancellation signal");
        started.resolve();
        upstreamSignal = signal;
        const abort = () => response.reject(signal.reason);
        signal.addEventListener("abort", abort, { once: true });
        if (signal.aborted) abort();
        return await response.promise;
      },
      { preconnect: originalFetch.preconnect },
    ),
  );
  const abort = new AbortController();
  const verifier = new CloudKitIdentity(
    "iCloud.example.synthetic",
    "api-token",
  );
  const pending = verifier.verify("fresh-proof", abort.signal);
  try {
    await started.promise;
    abort.abort();
    expect(upstreamSignal?.aborted).toBe(true);
    await expect(pending).rejects.toMatchObject({
      status: 503,
      code: "identity_unavailable",
    });
  } finally {
    abort.abort();
    response.reject(new Error("Fixture closed"));
    await pending.catch(() => {});
    fetchSpy.mockRestore();
  }
});
