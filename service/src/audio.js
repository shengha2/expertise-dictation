import { LIMITS, ServiceError, byteLength, onlyKeys, quotaError } from "./core.js";

export class AudioGuard {
  constructor(now = Date.now()) {
    this.started = now; this.lastInput = now; this.configured = false;
    this.updates = 0; this.bytes = 0; this.bufferBytes = 0; this.commits = 0; this.lastCommit = -Infinity;
    this.events = 0; this.tokens = 120; this.lastTokenTime = now;
  }
  accept(text, now = Date.now()) {
    if (typeof text !== "string" || text.length > LIMITS.messageBytes || byteLength(text) > LIMITS.messageBytes) throw new ServiceError();
    this.tokens = Math.min(120, this.tokens + Math.max(0, now - this.lastTokenTime) * 80 / 1000);
    this.lastTokenTime = now;
    if (this.tokens < 1 || ++this.events > 16000 || now - this.started > LIMITS.sessionSeconds * 1000) throw quotaError();
    this.tokens--;
    let event; try { event = JSON.parse(text); } catch { throw new ServiceError(); }
    if (event?.type === "session.update") {
      onlyKeys(event, ["type", "session", "event_id"]);
      const session = event.session; onlyKeys(session, ["type", "audio"]);
      onlyKeys(session.audio, ["input"]);
      const input = session.audio.input;
      onlyKeys(input, ["format", "transcription", "turn_detection", "noise_reduction"]);
      onlyKeys(input.format, ["type", "rate"]);
      const transcription = input.transcription;
      onlyKeys(transcription, ["model", "prompt", "keywords", "languages", "delay"]);
      if (session.type !== "transcription" || input.format.type !== "audio/pcm" || input.format.rate !== 24000 ||
          input.turn_detection !== null || transcription.model !== "gpt-live-transcribe" || this.bytes !== 0 || ++this.updates > 2) throw new ServiceError();
      if (transcription.prompt !== undefined && (typeof transcription.prompt !== "string" || byteLength(transcription.prompt) > 4096)) throw new ServiceError();
      if (transcription.keywords !== undefined && (!Array.isArray(transcription.keywords) || transcription.keywords.length > 100 ||
          transcription.keywords.some(word => typeof word !== "string" || !word.length || byteLength(word) > 128 || /[<>\r\n]/.test(word)))) throw new ServiceError();
      if (transcription.languages !== undefined && (!Array.isArray(transcription.languages) || transcription.languages.length > 20 ||
          transcription.languages.some(language => typeof language !== "string" || !/^(?:[a-z]{2,3}|zh-(?:cn|tw|hk))$/.test(language)))) throw new ServiceError();
      if (transcription.delay !== undefined && !["minimal", "low", "medium", "high", "xhigh"].includes(transcription.delay)) throw new ServiceError();
      if (input.noise_reduction !== undefined && input.noise_reduction !== null) {
        onlyKeys(input.noise_reduction, ["type"]);
        if (!["near_field", "far_field"].includes(input.noise_reduction.type)) throw new ServiceError();
      }
      this.configured = true; this.lastInput = now;
      return { event: { type: "session.update", session: { type: "transcription", audio: { input: {
        format: { type: "audio/pcm", rate: 24000 }, transcription, turn_detection: null,
        ...(input.noise_reduction !== undefined ? { noise_reduction: input.noise_reduction } : {}),
      } } } }, audioBytes: 0 };
    }
    if (!this.configured) throw new ServiceError();
    if (event?.type === "input_audio_buffer.append") {
      onlyKeys(event, ["type", "audio", "event_id"]);
      const audio = event.audio;
      if (typeof audio !== "string" || !audio.length || audio.length % 4 !== 0 ||
          !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(audio)) throw new ServiceError();
      const bytes = audio.length / 4 * 3 - (audio.endsWith("==") ? 2 : audio.endsWith("=") ? 1 : 0);
      const nextBytes = this.bytes + bytes;
      const elapsedSeconds = Math.max(0, now - this.started) / 1000;
      if (!bytes || bytes % 2 || nextBytes > LIMITS.audioSeconds * LIMITS.audioBytesPerSecond ||
          nextBytes > (60 + elapsedSeconds * 8) * LIMITS.audioBytesPerSecond) throw quotaError();
      this.bytes = nextBytes; this.bufferBytes += bytes; this.lastInput = now;
      return { event: { type: event.type, audio }, audioBytes: bytes };
    }
    if (event?.type === "input_audio_buffer.commit") {
      onlyKeys(event, ["type", "event_id"]);
      if (this.bufferBytes < 4800 || this.commits >= 5 || now - this.lastCommit < 1000) throw quotaError();
      this.commits++; this.lastCommit = now; this.bufferBytes = 0; this.lastInput = now;
      return { event: { type: event.type }, audioBytes: 0 };
    }
    if (event?.type === "input_audio_buffer.clear") {
      onlyKeys(event, ["type", "event_id"]);
      if (!this.bufferBytes) throw new ServiceError();
      this.bufferBytes = 0;
      return { event: { type: event.type }, audioBytes: 0 };
    }
    throw new ServiceError();
  }
}

/** Reconstruct responses: never relay provider errors, session configuration, or
 * request metadata. Transcript content is returned only to its originating socket. */
export function safeAudioEvent(text) {
  if (typeof text !== "string" || byteLength(text) > LIMITS.upstreamMessageBytes) throw new ServiceError();
  let event; try { event = JSON.parse(text); } catch { throw new ServiceError(); }
  if (!event || typeof event.type !== "string") throw new ServiceError();
  const id = value => typeof value === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(value) ? value : undefined;
  switch (event.type) {
  case "session.created": case "session.updated": case "transcription_session.created": case "transcription_session.updated":
    return { type: event.type, session: { type: "transcription" } };
  case "input_audio_buffer.committed":
    return { type: event.type, item_id: id(event.item_id), previous_item_id: id(event.previous_item_id) };
  case "input_audio_buffer.cleared": return { type: event.type };
  case "conversation.item.input_audio_transcription.delta":
  case "conversation.item.input_audio_transcription.completed": {
    const field = event.type.endsWith(".delta") ? "delta" : "transcript";
    if (typeof event[field] !== "string" || !id(event.item_id)) throw new ServiceError();
    return { type: event.type, item_id: event.item_id, content_index: 0, [field]: event[field] };
  }
  case "error": case "conversation.item.input_audio_transcription.failed":
    return { type: "error", error: { code: "provider_unavailable", message: "The transcription service could not complete this section. Your recording stays saved on your Mac." } };
  default: return null;
  }
}

export function relayAudio(client, upstream, ledger, lease, installation, ip, signal) {
  const guard = new AudioGuard();
  let closed = false, pendingBytes = 0, pendingCount = 0, outputBytes = 0, outputCount = 0;
  let chain = Promise.resolve();
  let reservationDay = Math.floor(Date.now() / 86400000), dailyBytes = 0, reservedMinutes = 1;
  const close = (code = 1000, error = null) => {
    if (closed) return; closed = true; clearInterval(timer);
    signal?.removeEventListener("abort", abort);
    if (error) {
      try { client.send(JSON.stringify({ type: "error", error: { code: error instanceof ServiceError ? error.code : "unavailable", message: error instanceof ServiceError ? error.message : "The dictation service disconnected. Your recording stays saved on your Mac." } })); } catch {}
    }
    try { client.close(code, code === 1000 ? "Session ended" : "Dictation session stopped"); } catch {}
    try { upstream.close(code, "Session ended"); } catch {}
    try { ledger.release(lease); } catch {}
  };
  const timer = setInterval(() => {
    const now = Date.now();
    if (now - guard.started >= LIMITS.sessionSeconds * 1000 || now - guard.lastInput >= LIMITS.idleSeconds * 1000) close(1008, new ServiceError(408, "timeout", "This dictation session timed out. Your recording stays saved on your Mac."));
  }, 5000);
  const abort = () => close(1001);
  client.addEventListener("message", event => {
    if (closed) return;
    const size = typeof event.data === "string" ? byteLength(event.data) : Infinity;
    if (size > LIMITS.messageBytes || pendingBytes + size > LIMITS.queueBytes || pendingCount >= LIMITS.queueMessages) { close(1008, quotaError()); return; }
    pendingBytes += size; pendingCount++;
    chain = chain.then(async () => {
      if (closed) return;
      const now = Date.now();
      const accepted = guard.accept(event.data, now);
      if (accepted.audioBytes) {
        const day = Math.floor(now / 86400000);
        if (day !== reservationDay) { reservationDay = day; dailyBytes = 0; reservedMinutes = 0; }
        dailyBytes += accepted.audioBytes;
        const minutes = Math.ceil(dailyBytes / (LIMITS.audioBytesPerSecond * 60));
        if (minutes > reservedMinutes) {
          ledger.reserve(installation, ip, (minutes - reservedMinutes) * LIMITS.audioMinuteMicroUSD, now);
          await ledger.storage.sync(); // Persist before releasing any newly reserved audio.
          reservedMinutes = minutes;
        }
      }
      if (!closed) upstream.send(JSON.stringify(accepted.event));
    }).catch(error => close(1008, error)).finally(() => { pendingBytes -= size; pendingCount--; });
  });
  upstream.addEventListener("message", event => {
    if (closed) return;
    try {
      const size = typeof event.data === "string" ? byteLength(event.data) : Infinity;
      if ((outputBytes += size) > 2 * 1024 * 1024 || ++outputCount > 10000) throw quotaError();
      const safe = safeAudioEvent(event.data);
      if (safe) client.send(JSON.stringify(safe));
    } catch (error) { close(1011, error); }
  });
  client.addEventListener("close", () => close());
  client.addEventListener("error", () => close(1011));
  upstream.addEventListener("close", () => close());
  upstream.addEventListener("error", () => close(1011));
  try { client.accept(); upstream.accept(); }
  catch (error) { close(1011); throw error; }
  signal?.addEventListener("abort", abort, { once: true });
  if (signal?.aborted) abort();
  return close;
}
