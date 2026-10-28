const originalFetch = globalThis.fetch;

globalThis.fetch = Object.assign(
  async (
    input: Parameters<typeof fetch>[0],
    init?: Parameters<typeof fetch>[1],
  ) => {
    const url = new URL(
      input instanceof Request ? input.url : input.toString(),
    );
    if (url.hostname !== "api.apple-cloudkit.com")
      return originalFetch(input, init);
    if (
      url.pathname !==
      "/database/1/iCloud.example.synthetic/production/public/users/caller"
    )
      throw new Error("Unexpected CloudKit endpoint");
    if (url.searchParams.get("ckAPIToken") === "transient-api-token")
      return Response.json(
        { serverErrorCode: "TRY_AGAIN_LATER" },
        { status: 503 },
      );
    if (
      url.searchParams.get("ckAPIToken") === "denied-api-token" ||
      url.searchParams.get("ckWebAuthToken") === "denied-proof"
    )
      return Response.json(
        { serverErrorCode: "ACCESS_DENIED" },
        { status: 403 },
      );
    if (url.searchParams.get("ckWebAuthToken") === "failed-api-proof")
      return Response.json(
        { serverErrorCode: "AUTHENTICATION_FAILED" },
        { status: 401 },
      );
    if (!url.searchParams.has("ckWebAuthToken"))
      return Response.json(
        { serverErrorCode: "AUTHENTICATION_REQUIRED" },
        { status: 421 },
      );
    return Response.json({ userRecordName: "synthetic-account" });
  },
  { preconnect: originalFetch.preconnect },
);
