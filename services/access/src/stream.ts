import { randomUUID } from "node:crypto";
import {
  AccessError,
  exactKeys,
  parseJSON,
  record,
  sampleRate,
} from "./protocol";

const maximumLanguages = 16;
const maximumVocabularyTerms = 500;
const providerVocabularyTerms = 50;
const providerTermLength = 50;
const pauseBytes = 1024 * 1024;
const resumeBytes = 256 * 1024;

export interface StreamSocket {
  pause(): void;
  resume(): void;
}

function strings(value: unknown, maximum: number) {
  if (
    !Array.isArray(value) ||
    value.length > maximum ||
    value.some((item) => typeof item !== "string")
  )
    throw new AccessError(400, "invalid_message");
  return (value as string[]).map((item) => item.trim()).filter(Boolean);
}

export function definition(languages: unknown, vocabulary: unknown) {
  const hints = strings(languages, maximumLanguages);
  const phrases = strings(vocabulary, maximumVocabularyTerms)
    .filter((phrase) => [...phrase].length <= providerTermLength)
    .slice(0, providerVocabularyTerms);
  const locale = hints.length === 1 ? hints[0] : undefined;
  if (locale !== undefined && !/^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$/.test(locale))
    throw new AccessError(400, "unsupported_transcription");
  return JSON.stringify({
    enhancedMode: {
      enabled: true,
      model: "MAI-Transcribe-2",
      modelOptions: { transcribeStyle: "clean", timestamps: "none" },
    },
    ...(phrases.length ? { phraseList: { phrases } } : {}),
    ...(locale ? { locales: [locale] } : {}),
  });
}

function streamingWAVHeader() {
  const header = Buffer.alloc(44);
  header.write("RIFF");
  header.writeUInt32LE(0xffff_ffff, 4);
  header.write("WAVEfmt ", 8);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(1, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(sampleRate * 2, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(0xffff_ffff, 40);
  return header;
}

export class StreamUpload {
  private readonly abort = new AbortController();
  private readonly stopped: AbortSignal;
  private readonly queue: Buffer[] = [];
  private queuedBytes = 0;
  private receivedBytes = 0;
  private audioBytes = 0;
  private definition: string | undefined;
  private finished = false;
  private paused = false;
  private wake: (() => void) | undefined;
  private readonly progressTimer: ReturnType<typeof setInterval>;
  private readonly headerTimer: ReturnType<typeof setTimeout>;
  private waitingSince: number | undefined = performance.now();
  private clientWaitMs = 0;
  private clientWaitInterrupted = false;
  private validationError: AccessError | undefined;
  private handedOff = false;
  private completed = false;

  constructor(
    private readonly socket: StreamSocket,
    private readonly limitSamples: number,
    signal: AbortSignal,
  ) {
    this.headerTimer = setTimeout(() => {
      if (!this.definition || this.receivedBytes < 2)
        this.fail(new AccessError(408, "upload_header_timeout"));
    }, 3000);
    this.headerTimer.unref();
    this.progressTimer = setInterval(() => {
      if (
        this.waitingSince !== undefined &&
        this.receivedBytes / 2 <
          (((this.clientWaitMs + performance.now() - this.waitingSince) / 1000 -
            10) *
            sampleRate) /
            2
      )
        this.fail(new AccessError(408, "upload_too_slow"));
    }, 1000);
    this.progressTimer.unref();
    const combined = AbortSignal.any([signal, this.abort.signal]);
    const stop = () => {
      this.clientWaitInterrupted ||= this.waitingSince !== undefined;
      this.signalInput();
    };
    combined.addEventListener("abort", stop, { once: true });
    if (combined.aborted) stop();
    this.stopped = combined;
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

  receive(message: string | Buffer) {
    try {
      if (this.stopped.aborted) return;
      if (typeof message !== "string") return this.append(message);
      const value = record(parseJSON(message));
      if (value.type === "start" && this.definition === undefined) {
        exactKeys(value, ["type", "languages", "vocabulary"]);
        this.definition = definition(value.languages, value.vocabulary);
      } else if (
        value.type === "finish" &&
        this.definition !== undefined &&
        !this.finished
      ) {
        exactKeys(value, ["type"]);
        this.finished = true;
      } else throw new AccessError(400, "invalid_message");
      this.signalInput();
    } catch (error) {
      this.fail(
        error instanceof AccessError
          ? error
          : new AccessError(400, "invalid_message"),
      );
    }
  }

  private append(audio: Buffer) {
    if (
      this.definition === undefined ||
      this.finished ||
      audio.length === 0 ||
      audio.length % 2 !== 0
    )
      throw new AccessError(400, "invalid_audio");
    this.receivedBytes += audio.length;
    if (this.receivedBytes > this.limitSamples * 2)
      throw new AccessError(413, "audio_limit_exceeded");
    this.queue.push(Buffer.from(audio));
    this.queuedBytes += audio.length;
    if (this.queuedBytes >= pauseBytes && !this.paused) {
      this.paused = true;
      this.socket.pause();
    }
    this.signalInput();
  }

  private fail(error: AccessError) {
    this.validationError ??= error;
    this.abort.abort(error);
  }

  private signalInput() {
    const wake = this.wake;
    this.wake = undefined;
    wake?.();
  }

  private async waitForClient(ready: () => boolean) {
    this.waitingSince ??= performance.now();
    try {
      while (!ready()) {
        if (this.stopped.aborted)
          throw this.validationError ?? new Error("input_stopped");
        await new Promise<void>((resolve) => {
          this.wake = resolve;
        });
      }
      if (this.stopped.aborted)
        throw this.validationError ?? new Error("input_stopped");
    } finally {
      this.clientWaitMs += performance.now() - this.waitingSince;
      this.waitingSince = undefined;
    }
  }

  private take() {
    const chunk = this.queue.shift();
    if (!chunk) return undefined;
    this.queuedBytes -= chunk.length;
    if (this.paused && this.queuedBytes <= resumeBytes) {
      this.paused = false;
      this.socket.resume();
    }
    return chunk;
  }

  async prepare(onDispatch: () => void) {
    await this.waitForClient(
      () =>
        this.definition !== undefined &&
        (this.queue.length > 0 || this.finished),
    );
    if (this.queue.length === 0) throw new AccessError(400, "invalid_audio");
    const boundary = randomUUID();
    const prefix = Buffer.concat([
      Buffer.from(
        `--${boundary}\r\nContent-Disposition: form-data; name="definition"\r\n\r\n${this.definition}\r\n--${boundary}\r\nContent-Disposition: form-data; name="audio"; filename="recording.wav"\r\nContent-Type: audio/wav\r\n\r\n`,
      ),
      streamingWAVHeader(),
    ]);
    clearTimeout(this.headerTimer);
    const self = this;
    async function* body() {
      onDispatch();
      self.handedOff = true;
      yield prefix;
      while (true) {
        const chunk = self.take();
        if (chunk) {
          self.audioBytes += chunk.length;
          yield chunk;
          continue;
        }
        if (self.finished) break;
        await self.waitForClient(() => self.queue.length > 0 || self.finished);
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
    this.queue.length = 0;
    this.queuedBytes = 0;
    if (this.paused) {
      this.paused = false;
      this.socket.resume();
    }
  }
}
