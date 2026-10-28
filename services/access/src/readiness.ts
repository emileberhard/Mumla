import type { AccessConfig } from "./config";
import { boundedBytes, parseJSON, record } from "./protocol";

export async function checkRouter(config: AccessConfig) {
  const signal = AbortSignal.timeout(3000);
  const response = await fetch(`${config.routerOrigin}/health`, {
    signal,
    redirect: "error",
  });
  const bytes = await boundedBytes(response.body, 64 * 1024, signal);
  const result = record(
    parseJSON(new TextDecoder("utf-8", { fatal: true }).decode(bytes)),
  );
  if (!response.ok || result.service !== "llm-router" || result.status !== "ok")
    throw new Error("Router health check failed");
}
