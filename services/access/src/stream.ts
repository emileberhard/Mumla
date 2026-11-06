import { randomUUID } from "node:crypto";
import {
  AccessError,
  exactKeys,
  parseJSON,
  record,
  sampleRate,
} from "./protocol";

const providerVocabularyTerms = 50;
const providerTermLength = 50;
const pauseBytes = 1024 * 1024;
const resumeBytes = 256 * 1024;
export const keptAudioSeconds = 600;
export const keptAudioBudgetBytes = 128 * 1024 * 1024;

export type Speakers = "onRequest" | "diarize";

export class KeptAudioBudget {
  private used = 0;

  constructor(private readonly limitBytes: number) {}

  reserve(bytes: number) {
    if (this.used + bytes > this.limitBytes) return false;
    this.used += bytes;
    return true;
  }

  release(bytes: number) {
    this.used -= bytes;
  }
}

export interface StreamSocket {
  pause(): void;
  resume(): void;
}

function strings(value: unknown) {
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string"))
    throw new AccessError(400, "invalid_message");
  return (value as string[]).map((item) => item.trim()).filter(Boolean);
}

function speakers(value: unknown): Speakers | undefined {
  if (value === undefined || value === "onRequest" || value === "diarize")
    return value;
  throw new AccessError(400, "invalid_message");
}

export function definition(
  languages: unknown,
  vocabulary: unknown,
  diarized = false,
) {
  const hints = strings(languages);
  const phrases = strings(vocabulary)
    .filter((phrase) => [...phrase].length <= providerTermLength)
    .slice(0, providerVocabularyTerms);
  const locale = hints.length === 1 ? hints[0] : undefined;
  if (locale !== undefined && !/^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$/.test(locale))
    throw new AccessError(400, "unsupported_transcription");
  return JSON.stringify({
    enhancedMode: {
      enabled: true,
      model: "MAI-Transcribe-2",
      modelOptions: {
        transcribeStyle: "clean",
        timestamps: diarized ? "word" : "none",
      },
    },
    ...(diarized ? { diarization: { enabled: true } } : {}),
    ...(phrases.length ? { phraseList: { phrases } } : {}),
    ...(locale ? { locales: [locale] } : {}),
  });
}

export interface VoicePhrase {
  speaker: number;
  text: string;
  words: [number, number][];
}

function isCount(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

export function voicePhrases(
  result: Record<string, unknown>,
): VoicePhrase[] | undefined {
  if (!Array.isArray(result.phrases)) return undefined;
  const phrases: VoicePhrase[] = [];
  for (const item of result.phrases) {
    if (!item || typeof item !== "object") return undefined;
    const { speaker, text, words = [] } = item as Record<string, unknown>;
    if (!isCount(speaker) || typeof text !== "string" || !Array.isArray(words))
      return undefined;
    const spans: [number, number][] = [];
    for (const word of words) {
      if (!word || typeof word !== "object") return undefined;
      const { offsetMilliseconds, durationMilliseconds } = word as Record<
        string,
        unknown
      >;
      if (!isCount(offsetMilliseconds) || !isCount(durationMilliseconds))
        return undefined;
      spans.push([offsetMilliseconds, durationMilliseconds]);
    }
    phrases.push({ speaker, text, words: spans });
  }
  return phrases;
}

export function wavHeader(dataBytes = 0xffff_ffff) {
  const header = Buffer.alloc(44);
  header.write("RIFF");
  header.writeUInt32LE(
    dataBytes === 0xffff_ffff ? dataBytes : 36 + dataBytes,
    4,
  );
  header.write("WAVEfmt ", 8);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(1, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(sampleRate * 2, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(dataBytes, 40);
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
  private diarizedDefinition: string | undefined;
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
  private finishedAt: number | undefined;
  private mode: Speakers | undefined;
  private kept: Buffer[] | undefined;
  private keptBytes = 0;
  private readonly voices = Promise.withResolvers<void>();
  private voicesWanted = false;

  constructor(
    private readonly socket: StreamSocket,
    private readonly limitSamples: number,
    signal: AbortSignal,
    private readonly budget: KeptAudioBudget,
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
  get audioEndedAt() {
    return this.finishedAt;
  }
  get speakers() {
    return this.mode;
  }
  get diarized() {
    return this.mode === "diarize";
  }
  get voicesRequest() {
    return this.voices.promise;
  }
  get keptAudio() {
    return this.kept;
  }

  get voicesDefinition() {
    return this.diarizedDefinition;
  }

  receive(message: string | Buffer) {
    try {
      if (typeof message !== "string") {
        if (!this.stopped.aborted) this.append(message);
        return;
      }
      const value = record(parseJSON(message));
      if (value.type === "voices") this.requestVoices(value);
      else if (!this.stopped.aborted) this.control(value);
    } catch (error) {
      if (this.stopped.aborted) return;
      this.fail(
        error instanceof AccessError
          ? error
          : new AccessError(400, "invalid_message"),
      );
    }
  }

  private requestVoices(value: Record<string, unknown>) {
    exactKeys(value, ["type"]);
    if (this.mode !== "onRequest" || !this.finished || this.voicesWanted)
      throw new AccessError(400, "invalid_message");
    this.voicesWanted = true;
    this.voices.resolve();
  }

  private control(value: Record<string, unknown>) {
    if (value.type === "start" && this.definition === undefined) {
      exactKeys(value, ["type", "languages", "vocabulary", "speakers"]);
      this.mode = speakers(value.speakers);
      this.definition = definition(
        value.languages,
        value.vocabulary,
        this.diarized,
      );
      if (this.mode === "onRequest") {
        this.diarizedDefinition = definition(
          value.languages,
          value.vocabulary,
          true,
        );
        this.kept = [];
      }
    } else if (
      value.type === "finish" &&
      this.definition !== undefined &&
      !this.finished
    ) {
      exactKeys(value, ["type"]);
      this.finished = true;
      this.finishedAt = performance.now();
    } else throw new AccessError(400, "invalid_message");
    this.signalInput();
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
    const copy = Buffer.from(audio);
    this.queue.push(copy);
    this.queuedBytes += audio.length;
    if (this.kept) this.keep(copy);
    if (this.queuedBytes >= pauseBytes && !this.paused) {
      this.paused = true;
      this.socket.pause();
    }
    this.signalInput();
  }

  private keep(audio: Buffer) {
    if (
      this.keptBytes + audio.length > keptAudioSeconds * sampleRate * 2 ||
      !this.budget.reserve(audio.length)
    )
      return this.releaseKeptAudio();
    this.kept?.push(audio);
    this.keptBytes += audio.length;
  }

  releaseKeptAudio() {
    this.budget.release(this.keptBytes);
    this.keptBytes = 0;
    this.kept = undefined;
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
      wavHeader(),
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
