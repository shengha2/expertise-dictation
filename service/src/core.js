export const LIMITS = Object.freeze({
  tokenSeconds: 3600, requestBytes: 128 * 1024, responseBytes: 512 * 1024,
  textOutputTokens: 32768, audioBytesPerSecond: 48000,
  audioMinuteMicroUSD: 30000, audioSeconds: 300, sessionSeconds: 480,
  idleSeconds: 150, messageBytes: 4 * 1024 * 1024, queueBytes: 4 * 1024 * 1024,
  queueMessages: 128, upstreamMessageBytes: 512 * 1024,
});
const encoder = new TextEncoder();
export const byteLength = value => encoder.encode(value).byteLength;
export class ServiceError extends Error {
  constructor(status = 400, code = "invalid_request", message = "This request is not supported by the dictation service.") {
    super(message); this.status = status; this.code = code;
  }
}
export const unavailable = () => new ServiceError(503, "unavailable", "The dictation service is temporarily unavailable. Your recording stays saved on your Mac.");
export const quotaError = () => new ServiceError(429, "usage_limit", "The free dictation service has reached its usage limit. Try again later; your recording stays saved on your Mac.");
export function errorResponse(error) {
  const safe = error instanceof ServiceError ? error : unavailable();
  return json({ error: { code: safe.code, message: safe.message } }, safe.status);
}
export function json(value, status = 200) {
  return Response.json(value, { status, headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } });
}
export function onlyKeys(object, keys) {
  if (!object || typeof object !== "object" || Array.isArray(object) || Object.keys(object).some(key => !keys.includes(key))) throw new ServiceError();
}
export function config(env) {
  function integer(name, fallback, max = 1_000_000_000) {
    const raw = env[name] ?? String(fallback);
    if (typeof raw !== "string" || !/^(0|[1-9][0-9]*)$/.test(raw)) return 0;
    const number = Number(raw);
    return Number.isSafeInteger(number) && number <= max ? number : 0;
  }
  return {
    budget: integer("DAILY_BUDGET_MICROUSD", 0),
    installationBudget: integer("INSTALL_DAILY_MICROUSD", 5_000_000),
    ipBudget: integer("IP_DAILY_MICROUSD", 10_000_000),
    configured: typeof env.OPENAI_API_KEY === "string" && env.OPENAI_API_KEY.length >= 16 &&
      typeof env.TOKEN_SIGNING_SECRET === "string" && env.TOKEN_SIGNING_SECRET.length >= 32,
  };
}
function base64url(bytes) { return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", ""); }
function decode64(value) {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) throw new ServiceError(401, "unauthorized", "Reconnect to the dictation service and try again.");
  return Uint8Array.from(atob(value.replaceAll("-", "+").replaceAll("_", "/")), c => c.charCodeAt(0));
}
async function signingKey(secret) {
  return crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}
export async function digest(secret, purpose, value) {
  const bytes = await crypto.subtle.sign("HMAC", await signingKey(secret), encoder.encode(`${purpose}\0${value}`));
  return [...new Uint8Array(bytes)].map(b => b.toString(16).padStart(2, "0")).join("");
}
export async function mintToken(secret, installation, now = Date.now()) {
  const seconds = Math.floor(now / 1000);
  const payload = base64url(encoder.encode(JSON.stringify({ v: 1, iid: installation, iat: seconds, exp: seconds + LIMITS.tokenSeconds })));
  const sig = base64url(new Uint8Array(await crypto.subtle.sign("HMAC", await signingKey(secret), encoder.encode(`dictation-token-v1.${payload}`))));
  return { token: `${payload}.${sig}`, expires_at: seconds + LIMITS.tokenSeconds };
}
export async function verifyToken(secret, authorization, now = Date.now()) {
  const denied = () => new ServiceError(401, "unauthorized", "Reconnect to the dictation service and try again.");
  try {
    if (typeof authorization !== "string" || !authorization.startsWith("Bearer ") || authorization.length > 768) throw denied();
    const parts = authorization.slice(7).split(".");
    if (parts.length !== 2) throw denied();
    const valid = await crypto.subtle.verify("HMAC", await signingKey(secret), decode64(parts[1]), encoder.encode(`dictation-token-v1.${parts[0]}`));
    if (!valid) throw denied();
    const body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(decode64(parts[0])));
    const seconds = Math.floor(now / 1000);
    if (body.v !== 1 || !/^[a-f0-9]{64}$/.test(body.iid) || !Number.isInteger(body.exp) || !Number.isInteger(body.iat) ||
        body.iat > seconds + 30 || body.exp <= seconds || body.exp - body.iat !== LIMITS.tokenSeconds) throw denied();
    return body.iid;
  } catch { throw denied(); }
}
export function installationID(value) {
  onlyKeys(value, ["installation_id"]);
  if (typeof value.installation_id !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value.installation_id)) throw new ServiceError();
  return value.installation_id.toLowerCase();
}
export async function readJSON(body, maximum, timeoutMS = 10000) {
  if (!body) throw new ServiceError();
  const reader = body.getReader();
  let timer;
  try {
    const reading = (async () => {
      const chunks = []; let size = 0;
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > maximum) throw new ServiceError(413, "too_large", "This dictation section is too large. Split it into smaller sections and try again.");
        chunks.push(value);
      }
      const bytes = new Uint8Array(size); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
      try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
      catch { throw new ServiceError(); }
    })();
    return await Promise.race([reading, new Promise((_, reject) => { timer = setTimeout(() => reject(new ServiceError(408, "timeout", "The request took too long. Please try again.")), timeoutMS); })]);
  } finally { clearTimeout(timer); reader.cancel().catch(() => {}); }
}
export function validateChat(value) {
  onlyKeys(value, ["model", "messages", "max_completion_tokens", "reasoning_effort", "service_tier", "stream"]);
  if (value.model !== "gpt-6-luna" || value.reasoning_effort !== "none" ||
      (value.service_tier !== undefined && value.service_tier !== "default") ||
      (value.stream !== undefined && value.stream !== false) ||
      !Number.isInteger(value.max_completion_tokens) || value.max_completion_tokens < 1 || value.max_completion_tokens > LIMITS.textOutputTokens ||
      !Array.isArray(value.messages) || value.messages.length !== 2) throw new ServiceError();
  for (let i = 0; i < 2; i++) {
    const item = value.messages[i]; onlyKeys(item, ["role", "content"]);
    if (item.role !== ["system", "user"][i] || typeof item.content !== "string" || !item.content.trim()) throw new ServiceError();
  }
  const bytes = byteLength(JSON.stringify(value.messages));
  if (bytes > LIMITS.requestBytes) throw new ServiceError(413, "too_large", "This dictation section is too large.");
  const request = { model: "gpt-6-luna", messages: value.messages, max_completion_tokens: value.max_completion_tokens,
    reasoning_effort: "none", service_tier: "default", stream: false, store: false };
  // One UTF-8 byte per input token is an upper bound for byte-based tokenization.
  // Add framing allowance, reserve 2x current standard prices, and never refund.
  const reserve = Math.ceil((bytes + 4096) / 5) + value.max_completion_tokens + 1000;
  return { request, reserve };
}
export function safeChatResponse(value) {
  const choice = value?.choices?.[0];
  if (!choice || typeof choice.message?.content !== "string" || !["stop", "length", "content_filter"].includes(choice.finish_reason)) throw unavailable();
  return { model: "gpt-6-luna", choices: [{ index: 0, message: { role: "assistant", content: choice.message.content }, finish_reason: choice.finish_reason }] };
}
