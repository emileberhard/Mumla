import { randomUUID } from "node:crypto";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import Busboy, {
  type BusboyFileStream,
  type BusboyInstance,
} from "@fastify/busboy";
import {
  AccessError,
  exactKeys,
  parseJSON,
  record,
  sampleRate,
} from "./protocol";

function definition(text: string) {
  const value = record(parseJSON(text));
  exactKeys(value, ["enhancedMode", "phraseList", "locales"]);
  const mode = record(value.enhancedMode);
  exactKeys(mode, ["enabled", "model", "modelOptions"]);
  const options = record(mode.modelOptions);
  exactKeys(options, ["transcribeStyle", "timestamps"]);
  if (
    mode.enabled !== true ||
    mode.model !== "MAI-Transcribe-2" ||
    options.transcribeStyle !== "clean" ||
    (options.timestamps !== undefined && options.timestamps !== "none")
  )
    throw new AccessError(400, "unsupported_transcription");
  if (value.locales !== undefined) {
    if (
      !Array.isArray(value.locales) ||
      value.locales.length > 1 ||
      value.locales.some(
        (locale) =>
          typeof locale !== "string" ||
          !/^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$/.test(locale),
      )
    )
      throw new AccessError(400, "unsupported_transcription");
  }
  if (value.phraseList !== undefined) {
    const list = record(value.phraseList);
    exactKeys(list, ["phrases"]);
    if (
      !Array.isArray(list.phrases) ||
      list.phrases.length > 50 ||
      list.phrases.some(
        (phrase) =>
          typeof phrase !== "string" ||
          [...phrase].length > 50 ||
          phrase.length === 0,
      )
    )
      throw new AccessError(400, "unsupported_transcription");
  }
  options.timestamps = "none";
  return JSON.stringify(value);
}

function wavHeader(header: Buffer, limitSamples: number) {
  const bytes = header.readUInt32LE(40);
  const streaming = bytes === 0xffff_ffff;
  if (
    !header.subarray(0, 4).equals(Buffer.from("RIFF")) ||
    !header.subarray(8, 16).equals(Buffer.from("WAVEfmt ")) ||
    header.readUInt32LE(16) !== 16 ||
    header.readUInt16LE(20) !== 1 ||
    header.readUInt16LE(22) !== 1 ||
    header.readUInt32LE(24) !== sampleRate ||
    header.readUInt32LE(28) !== sampleRate * 2 ||
    header.readUInt16LE(32) !== 2 ||
    header.readUInt16LE(34) !== 16 ||
    !header.subarray(36, 40).equals(Buffer.from("data")) ||
    header.readUInt32LE(4) !== (streaming ? 0xffff_ffff : 36 + bytes) ||
    (!streaming && (bytes === 0 || bytes % 2 !== 0 || bytes > limitSamples * 2))
  )
    throw new AccessError(400, "invalid_audio");
  return streaming ? null : bytes;
}

export class TranscriptionUpload {
  private readonly abort = new AbortController();
  private readonly parser: BusboyInstance;
  private readonly parsed: Promise<void>;
  private readonly fileReady: Promise<BusboyFileStream>;
  private definition = "";
  private audio: BusboyFileStream | undefined;
  private audioBytes = 0;
  private readonly progressTimer: ReturnType<typeof setInterval>;
  private waitingSince: number | undefined = performance.now();
  private clientWaitMs = 0;
  private clientWaitInterrupted = false;
  private headerTimer: ReturnType<typeof setTimeout> | undefined;
  private validationError: AccessError | undefined;
  private handedOff = false;
  private completed = false;

  constructor(
    request: Request,
    private readonly limitSamples: number,
    signal: AbortSignal,
  ) {
    const contentType = request.headers.get("content-type") ?? "";
    const boundary =
      /^multipart\/form-data;\s*boundary=([A-Za-z0-9-]{1,70})$/.exec(
        contentType,
      )?.[1];
    if (!boundary || !request.body || request.headers.has("content-encoding")) {
      throw new AccessError(415, "invalid_content_type");
    }
    const reader = request.body.getReader();
    const input = Readable.from(
      (async function* () {
        try {
          while (true) {
            const { value, done } = await reader.read();
            if (done) break;
            yield Buffer.from(value);
          }
        } finally {
          await reader.cancel().catch(() => {});
          reader.releaseLock();
        }
      })(),
    );
    const start = Buffer.from(`--${boundary}\r\n`);
    const close = Buffer.from(`\r\n--${boundary}--`);
    const suffix = Buffer.from("\r\n");
    let matchedStart = 0;
    let tail = Buffer.alloc(0);
    let closed = false;
    let matchedSuffix = 0;
    let size = 0;
    const wireLimit = this.limitSamples * 2 + 16 * 1024;
    const wire = new Transform({
      transform(chunk: Buffer, _encoding, callback) {
        size += chunk.length;
        if (size > wireLimit)
          return callback(new AccessError(413, "audio_limit_exceeded"));
        const prefix = chunk.subarray(0, start.length - matchedStart);
        if (
          !prefix.equals(
            start.subarray(matchedStart, matchedStart + prefix.length),
          )
        )
          return callback(new AccessError(400, "invalid_multipart"));
        matchedStart += prefix.length;
        let suffixAt = 0;
        if (!closed) {
          const crossing = Buffer.concat([
            tail,
            chunk.subarray(0, close.length - 1),
          ]);
          const crossAt = crossing.indexOf(close);
          const withinAt = chunk.indexOf(close);
          const endAt =
            crossAt >= 0
              ? crossAt + close.length - tail.length
              : withinAt >= 0
                ? withinAt + close.length
                : -1;
          if (endAt >= 0) {
            closed = true;
            suffixAt = endAt;
          }
          tail =
            chunk.length >= close.length - 1
              ? Buffer.from(chunk.subarray(1 - close.length))
              : Buffer.concat([tail, chunk]).subarray(1 - close.length);
        }
        if (closed) {
          const ending = chunk.subarray(suffixAt);
          if (
            ending.length > suffix.length - matchedSuffix ||
            !ending.equals(
              suffix.subarray(matchedSuffix, matchedSuffix + ending.length),
            )
          )
            return callback(new AccessError(400, "invalid_multipart"));
          matchedSuffix += ending.length;
        }
        callback(null, chunk);
      },
      flush(callback) {
        callback(
          matchedStart === start.length &&
            closed &&
            matchedSuffix === suffix.length
            ? null
            : new AccessError(400, "invalid_multipart"),
        );
      },
    });
    this.parser = new Busboy({
      headers: { "content-type": contentType },
      fileHwm: 64 * 1024,
      limits: {
        fields: 1,
        files: 1,
        parts: 2,
        fieldSize: 12 * 1024,
        fileSize: limitSamples * 2 + 45,
        headerSize: 1024,
        headerPairs: 8,
      },
    });
    let resolveFile: (file: BusboyFileStream) => void;
    let rejectFile: (error: unknown) => void;
    this.fileReady = new Promise((resolve, reject) => {
      resolveFile = resolve;
      rejectFile = reject;
    });
    const fail = (error: unknown) => {
      if (error instanceof AccessError && !this.validationError)
        this.validationError = error;
      rejectFile(this.validationError ?? error);
      this.audio?.destroy(
        error instanceof Error ? error : new Error("invalid_upload"),
      );
      this.abort.abort(error);
    };
    wire.on("error", fail);
    this.parser.on("error", fail);
    this.headerTimer = setTimeout(() => {
      if ((this.audio?.bytesRead ?? 0) < 46)
        fail(new AccessError(408, "upload_header_timeout"));
    }, 3000);
    this.headerTimer.unref();
    this.progressTimer = setInterval(() => {
      const received = Math.max(0, (this.audio?.bytesRead ?? 0) - 44) / 2;
      if (
        this.waitingSince !== undefined &&
        received <
          (((this.clientWaitMs + performance.now() - this.waitingSince) / 1000 -
            10) *
            sampleRate) /
            2
      )
        fail(new AccessError(408, "upload_too_slow"));
    }, 1000);
    this.progressTimer.unref();
    this.parser.on("field", (name, value, truncatedName, truncatedValue) => {
      try {
        if (
          name !== "definition" ||
          this.definition ||
          this.audio ||
          truncatedName ||
          truncatedValue
        ) {
          throw new AccessError(400, "invalid_multipart");
        }
        this.definition = definition(value);
      } catch (error) {
        fail(error);
      }
    });
    this.parser.on("file", (name, file, _filename, encoding, mimeType) => {
      this.audio = file;
      file.on("error", () => {});
      if (
        name !== "audio" ||
        !this.definition ||
        !["7bit", "binary"].includes(encoding) ||
        mimeType !== "audio/wav"
      ) {
        fail(new AccessError(400, "invalid_multipart"));
      } else {
        file.on("limit", () =>
          fail(new AccessError(413, "audio_limit_exceeded")),
        );
        resolveFile(file);
      }
    });
    for (const event of ["partsLimit", "filesLimit", "fieldsLimit"] as const) {
      this.parser.on(event, () =>
        fail(new AccessError(400, "invalid_multipart")),
      );
    }
    const combined = AbortSignal.any([signal, this.abort.signal]);
    const cancelInput = () => {
      this.clientWaitInterrupted = this.waitingSince !== undefined;
      void reader.cancel().catch(() => {});
    };
    combined.addEventListener("abort", cancelInput, { once: true });
    if (combined.aborted) cancelInput();
    this.parsed = pipeline(input, wire, this.parser, { signal: combined })
      .then(() => {})
      .finally(() => combined.removeEventListener("abort", cancelInput));
    void this.parsed.then(() => {
      if (!this.audio) rejectFile(new AccessError(400, "invalid_multipart"));
    }, fail);
    void this.fileReady.catch(() => {});
  }

  get samples() {
    return Math.floor(this.audioBytes / 2);
  }

  get failure() {
    return this.validationError;
  }
  get bodyHandedOff() {
    return this.handedOff;
  }
  get isComplete() {
    return this.completed;
  }
  get interruptedWhileWaitingForClient() {
    return this.clientWaitInterrupted;
  }

  private async waitForClient<T>(operation: () => Promise<T>): Promise<T> {
    this.waitingSince ??= performance.now();
    try {
      return await operation();
    } finally {
      this.clientWaitMs += performance.now() - this.waitingSince;
      this.waitingSince = undefined;
    }
  }

  async prepare(onDispatch: () => void) {
    const file = await this.waitForClient(() => this.fileReady);
    const iterator = file[Symbol.asyncIterator]();
    let buffered = Buffer.alloc(0);
    while (buffered.length < 44) {
      const chunk = await this.waitForClient(() => iterator.next());
      if (chunk.done) throw new AccessError(400, "invalid_audio");
      buffered = Buffer.concat([buffered, chunk.value]);
    }
    const expectedBytes = wavHeader(
      buffered.subarray(0, 44),
      this.limitSamples,
    );
    const maximumBytes = Math.min(
      expectedBytes ?? this.limitSamples * 2,
      this.limitSamples * 2,
    );
    const boundary = randomUUID();
    const prefix = Buffer.from(
      `--${boundary}\r\nContent-Disposition: form-data; name="definition"\r\n\r\n${this.definition}\r\n--${boundary}\r\nContent-Disposition: form-data; name="audio"; filename="recording.wav"\r\nContent-Type: audio/wav\r\n\r\n`,
    );
    const self = this;
    async function* body() {
      onDispatch();
      self.handedOff = true;
      yield prefix;
      yield buffered.subarray(0, 44);
      let pcm = buffered.subarray(44);
      while (true) {
        const accepted = Math.min(pcm.length, maximumBytes - self.audioBytes);
        if (accepted > 0) {
          self.audioBytes += accepted;
          yield pcm.subarray(0, accepted);
        }
        if (accepted < pcm.length)
          throw new AccessError(
            expectedBytes === null ? 413 : 400,
            expectedBytes === null ? "audio_limit_exceeded" : "invalid_audio",
          );
        const next = await self.waitForClient(() => iterator.next());
        if (next.done) break;
        pcm = Buffer.from(next.value);
      }
      await self.waitForClient(() => self.parsed);
      if (
        self.audioBytes === 0 ||
        self.audioBytes % 2 !== 0 ||
        (expectedBytes !== null && self.audioBytes !== expectedBytes)
      ) {
        throw new AccessError(400, "invalid_audio");
      }
      self.completed = true;
      clearInterval(self.progressTimer);
      yield Buffer.from(`\r\n--${boundary}--\r\n`);
    }
    const outgoing = body();
    return {
      signal: this.abort.signal,
      contentType: `multipart/form-data; boundary=${boundary}`,
      body: new ReadableStream<Uint8Array>(
        {
          async pull(controller) {
            try {
              const next = await outgoing.next();
              if (next.done) controller.close();
              else controller.enqueue(next.value);
            } catch (error) {
              if (error instanceof AccessError && !self.validationError)
                self.validationError = error;
              controller.error(error);
            }
          },
          cancel() {
            self.abort.abort();
          },
        },
        { highWaterMark: 0 },
      ),
    };
  }

  async close() {
    clearTimeout(this.headerTimer);
    clearInterval(this.progressTimer);
    this.abort.abort();
    this.audio?.destroy();
    await this.parsed.catch(() => {});
  }
}
