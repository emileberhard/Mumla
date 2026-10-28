import { visit } from "jsonc-parser";

export const sampleRate = 16_000;
export const maximumAudioSeconds = 120;
export const sessionLifetimeMs = 30 * 24 * 60 * 60 * 1000;
export const transcriptionPath =
  "/vendors/azure-speech/speechtotext/transcriptions:transcribe";

export class AccessError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
  ) {
    super(code);
  }
}

export class RequestIncident extends AccessError {
  constructor(readonly incidentCode: string) {
    super(503, "service_unavailable");
  }
}

export class OperatorIncident extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

export function parseJSON(text: string): unknown {
  const objects: Set<string>[] = [];
  let depth = 0;
  function begin() {
    if (++depth > 32) throw new AccessError(400, "invalid_json");
  }
  visit(
    text,
    {
      onObjectBegin() {
        begin();
        objects.push(new Set());
      },
      onObjectProperty(key) {
        const current = objects.at(-1);
        if (!current) throw new AccessError(400, "invalid_json");
        if (current.has(key)) throw new AccessError(400, "duplicate_json_key");
        current.add(key);
      },
      onObjectEnd() {
        objects.pop();
        depth--;
      },
      onArrayBegin: begin,
      onArrayEnd() {
        depth--;
      },
      onError() {
        throw new AccessError(400, "invalid_json");
      },
    },
    {
      disallowComments: true,
      allowTrailingComma: false,
      allowEmptyContent: false,
    },
  );
  return JSON.parse(text);
}

export function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new AccessError(400, "invalid_request");
  }
  return value as Record<string, unknown>;
}

export function exactKeys(value: Record<string, unknown>, allowed: string[]) {
  if (Object.keys(value).some((key) => !allowed.includes(key))) {
    throw new AccessError(400, "invalid_request");
  }
}

export function integer(value: unknown, minimum: number, maximum: number) {
  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < minimum ||
    value > maximum
  ) {
    throw new AccessError(400, "invalid_request");
  }
  return value;
}

export async function boundedBytes(
  body: ReadableStream<Uint8Array> | null,
  limit: number,
  signal: AbortSignal,
): Promise<Uint8Array> {
  if (!body) return new Uint8Array();
  const reader = body.getReader();
  const cancel = () => {
    void reader.cancel().catch(() => {});
  };
  signal.addEventListener("abort", cancel, { once: true });
  if (signal.aborted) cancel();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (signal.aborted) throw new AccessError(408, "request_timeout");
      if (done) break;
      size += value.byteLength;
      if (size > limit) throw new AccessError(413, "body_too_large");
      chunks.push(value);
    }
  } catch (error) {
    await reader.cancel().catch(() => {});
    throw error;
  } finally {
    signal.removeEventListener("abort", cancel);
    reader.releaseLock();
  }
  return Buffer.concat(chunks, size);
}

export async function jsonBody(
  request: Request,
  limit: number,
  signal: AbortSignal,
) {
  if (
    request.headers.get("content-type")?.split(";", 1)[0]?.trim() !==
      "application/json" ||
    request.headers.has("content-encoding")
  ) {
    throw new AccessError(415, "invalid_content_type");
  }
  const bytes = await boundedBytes(request.body, limit, signal);
  try {
    return record(
      parseJSON(new TextDecoder("utf-8", { fatal: true }).decode(bytes)),
    );
  } catch (error) {
    if (error instanceof AccessError) throw error;
    throw new AccessError(400, "invalid_json");
  }
}
