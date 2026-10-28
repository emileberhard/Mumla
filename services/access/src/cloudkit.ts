import { createHash } from "node:crypto";
import {
  AccessError,
  boundedBytes,
  OperatorIncident,
  parseJSON,
  RequestIncident,
  record,
} from "./protocol";

export interface IdentityVerifier {
  check(): Promise<boolean>;
  verify(webAuthToken: string, signal: AbortSignal): Promise<string>;
}

export class CloudKitIdentity implements IdentityVerifier {
  private verified = false;
  private checking: Promise<void> | undefined;
  private retryAt = 0;
  private retryDelay = 1000;
  private reportAfter = 0;
  constructor(
    private readonly container: string,
    private readonly apiToken: string,
  ) {}

  private async caller(webAuthToken: string | null, signal: AbortSignal) {
    const url = new URL(
      `https://api.apple-cloudkit.com/database/1/${this.container}/production/public/users/caller`,
    );
    url.searchParams.set("ckAPIToken", this.apiToken);
    if (webAuthToken !== null)
      url.searchParams.set("ckWebAuthToken", webAuthToken);
    const response = await fetch(url, { redirect: "error", signal });
    if (
      webAuthToken === null &&
      [200, 400, 403, 404].includes(response.status)
    ) {
      void response.body?.cancel().catch(() => {});
      throw new OperatorIncident(
        response.status === 403
          ? "cloudkit_access_denied"
          : "cloudkit_configuration_invalid",
      );
    }
    const bytes = await boundedBytes(response.body, 64 * 1024, signal);
    return { status: response.status, bytes };
  }

  async check() {
    if (this.verified || Date.now() < this.retryAt) return this.verified;
    this.checking ??= this.probe().finally(() => {
      this.checking = undefined;
    });
    await this.checking;
    return this.verified;
  }

  private async probe() {
    try {
      const { status, bytes } = await this.caller(
        null,
        AbortSignal.timeout(3000),
      );
      const result = record(
        parseJSON(new TextDecoder("utf-8", { fatal: true }).decode(bytes)),
      );
      if (result.serverErrorCode === "ACCESS_DENIED")
        throw new OperatorIncident("cloudkit_access_denied");
      if (status === 401 && result.serverErrorCode === "AUTHENTICATION_FAILED")
        throw new OperatorIncident("cloudkit_configuration_invalid");
      if (
        status === 421 &&
        result.serverErrorCode === "AUTHENTICATION_REQUIRED"
      ) {
        this.verified = true;
        return;
      }
    } catch (error) {
      if (error instanceof OperatorIncident) throw error;
    }
    const now = Date.now();
    this.retryAt = now + this.retryDelay * (0.8 + Math.random() * 0.4);
    this.retryDelay = Math.min(60_000, this.retryDelay * 2);
    if (now >= this.reportAfter) {
      this.reportAfter = now + 60_000;
      console.error(
        JSON.stringify({
          event: "access_service_incident",
          code: "cloudkit_unavailable",
        }),
      );
    }
  }

  async verify(webAuthToken: string, signal: AbortSignal): Promise<string> {
    await this.check();
    if (!this.verified) throw new AccessError(503, "identity_unavailable");
    try {
      signal.throwIfAborted();
      const { status, bytes } = await this.caller(
        webAuthToken,
        AbortSignal.any([signal, AbortSignal.timeout(10_000)]),
      );
      if (status === 403) throw new RequestIncident("cloudkit_access_denied");
      const result = record(
        parseJSON(new TextDecoder("utf-8", { fatal: true }).decode(bytes)),
      );
      if (result.serverErrorCode === "ACCESS_DENIED")
        throw new RequestIncident("cloudkit_access_denied");
      if (status === 401 && result.serverErrorCode === "AUTHENTICATION_FAILED")
        throw new RequestIncident("cloudkit_configuration_invalid");
      if (
        status === 421 &&
        ["AUTHENTICATION_REQUIRED", "AUTHENTICATION_FAILED"].includes(
          String(result.serverErrorCode),
        )
      ) {
        throw new AccessError(401, "invalid_identity");
      }
      if (status < 200 || status >= 300 || result.serverErrorCode)
        throw new AccessError(503, "identity_unavailable");
      const name = result.userRecordName;
      if (typeof name !== "string" || name.length === 0 || name.length > 1024) {
        throw new AccessError(503, "identity_unavailable");
      }
      const hash = createHash("sha256");
      for (const part of [this.container, "production", name]) {
        const bytes = Buffer.from(part);
        const length = Buffer.alloc(4);
        length.writeUInt32BE(bytes.length);
        hash.update(length).update(bytes);
      }
      return hash.digest("hex");
    } catch (error) {
      if (error instanceof RequestIncident) throw error;
      if (error instanceof AccessError && error.code === "invalid_identity")
        throw error;
      throw new AccessError(503, "identity_unavailable");
    }
  }
}
