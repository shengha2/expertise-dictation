import test from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { config, digest, mintToken, verifyToken, validateChat, safeChatResponse, readJSON, errorResponse, installationID, LIMITS } from "../src/core.js";
import { AudioGuard, safeAudioEvent, relayAudio } from "../src/audio.js";
import { Ledger } from "../src/ledger.js";
import { WebSocketPair } from "miniflare";

const secret = "synthetic-signing-secret-not-a-live-secret-1234";
const installation = "a".repeat(64), ip = "b".repeat(64);
const chat = () => ({ model: "gpt-6-luna", reasoning_effort: "none", max_completion_tokens: 1000,
  messages: [{ role: "system", content: "Keep every detail." }, { role: "user", content: "Hello. 你好。" }] });
const session = () => ({ type: "session.update", session: { type: "transcription", audio: { input: {
  format: { type: "audio/pcm", rate: 24000 }, turn_detection: null, noise_reduction: { type: "near_field" },
  transcription: { model: "gpt-live-transcribe", prompt: "A synthetic fixture.", keywords: ["Expertise"], languages: ["en", "zh-cn"], delay: "low" },
} } } });
const audio = bytes => JSON.stringify({ type: "input_audio_buffer.append", audio: Buffer.alloc(bytes).toString("base64") });
function storage() {
  const db = new DatabaseSync(":memory:"); let nesting = 0;
  return {
    sql: { exec(query, ...args) { const rows = db.prepare(query).all(...args); return { toArray: () => rows }; } },
    transactionSync(callback) {
      const savepoint = `tx${nesting++}`; db.exec(`SAVEPOINT ${savepoint}`);
      try { const result = callback(); db.exec(`RELEASE ${savepoint}`); return result; }
      catch (error) { db.exec(`ROLLBACK TO ${savepoint}`); db.exec(`RELEASE ${savepoint}`); throw error; }
      finally { nesting--; }
    },
    async sync() {}, close() { db.close(); },
  };
}
function ledger(t, budget = 1_000_000, installationBudget = budget) {
  const s = storage(); t.after(() => s.close());
  return new Ledger(s, { budget, installationBudget, ipBudget: budget });
}

test("tokens reject tampering, expiry, future issuance and another secret", async () => {
  const now = 1_800_000_000_000;
  const result = await mintToken(secret, installation, now);
  assert.equal(await verifyToken(secret, `Bearer ${result.token}`, now), installation);
  const [payload, signature] = result.token.split(".");
  const changedSignature = `${signature[0] === "a" ? "b" : "a"}${signature.slice(1)}`;
  await assert.rejects(verifyToken(secret, `Bearer ${payload}.${changedSignature}`, now));
  await assert.rejects(verifyToken(secret, `Bearer ${result.token}`, now + 3_600_000));
  await assert.rejects(verifyToken(secret, `Bearer ${result.token}`, now - 60_000));
  await assert.rejects(verifyToken(`${secret}other`, `Bearer ${result.token}`, now));
  for (const header of [null, "Bearer invalid", "Basic secret", `Bearer ${"a".repeat(1000)}`]) await assert.rejects(verifyToken(secret, header, now));
});
test("IP and installation pseudonyms use separate HMAC domains", async () => {
  const a = await digest(secret, "ip", "192.0.2.1"), b = await digest(secret, "installation", "192.0.2.1");
  assert.match(a, /^[a-f0-9]{64}$/); assert.notEqual(a, b); assert.notEqual(a, await digest(`${secret}2`, "ip", "192.0.2.1"));
});
test("deployment defaults fail closed and malformed budgets cannot enable it", () => {
  assert.equal(config({}).budget, 0); assert.equal(config({}).configured, false);
  for (const raw of ["-1", "1.5", "1e7", "Infinity", "1000000001"]) assert.equal(config({ DAILY_BUDGET_MICROUSD: raw }).budget, 0);
  assert.throws(() => installationID({ installation_id: "arbitrary-user-id" }));
  assert.equal(installationID({ installation_id: "d3bb7d89-8d6b-4cc7-a755-0e457ef7d2ca" }), "d3bb7d89-8d6b-4cc7-a755-0e457ef7d2ca");
});
test("chat preserves text and reserves above current token price upper bound", () => {
  const result = validateChat(chat());
  assert.deepEqual(result.request.messages, chat().messages);
  assert.equal(result.request.store, false); assert.equal(result.request.service_tier, "default");
  assert(result.reserve >= (Buffer.byteLength(JSON.stringify(chat().messages)) + 4096) * 0.1 + 1000 * 0.5);
});
test("chat refuses arbitrary model, tools, images, streaming, priority and unbounded output", () => {
  for (const patch of [ { model: "gpt-6-astra" }, { tools: [] }, { stream: true }, { service_tier: "priority" },
    { reasoning_effort: "high" }, { max_completion_tokens: 0 }, { max_completion_tokens: Infinity }, { max_completion_tokens: 32769 }, { n: 2 } ]) assert.throws(() => validateChat({ ...chat(), ...patch }));
  const image = chat(); image.messages[1].content = [{ type: "image_url", image_url: { url: "https://example.com" } }]; assert.throws(() => validateChat(image));
  const big = chat(); big.messages[1].content = "中".repeat(50000); assert.throws(() => validateChat(big));
});
test("bounded reader rejects oversized, malformed and stalled bodies", async () => {
  assert.deepEqual(await readJSON(new Response('{"ok":true}').body, 100), { ok: true });
  await assert.rejects(readJSON(new Response("x".repeat(101)).body, 100));
  await assert.rejects(readJSON(new Response("not JSON").body, 100));
  await assert.rejects(readJSON(new ReadableStream({}), 100, 10));
});
test("provider metadata and raw errors are not sent to clients", async () => {
  const result = safeChatResponse({ secret: "DO NOT ECHO", choices: [{ message: { content: "Fixture answer", debug: "private" }, finish_reason: "stop" }] });
  assert.equal(JSON.stringify(result).includes("private"), false); assert.equal(JSON.stringify(result).includes("DO NOT ECHO"), false);
  assert.throws(() => safeChatResponse({ error: { message: "provider secret" } }));
  const response = await errorResponse(new Error("Authorization: Bearer sensitive-fixture-value")).text();
  assert(!response.includes("sensitive-fixture-value"));
  assert.equal(safeAudioEvent(JSON.stringify({ type: "error", error: { message: "sensitive-fixture-value" } })).error.code, "provider_unavailable");
});
test("atomic global budget cannot be overspent by concurrent reservation requests", async t => {
  const l = ledger(t, 100);
  const settled = await Promise.allSettled(Array.from({ length: 100 }, async (_, n) => l.reserve(`${installation}${n}`, ip, 17, 1_800_000_000_000)));
  assert.equal(settled.filter(x => x.status === "fulfilled").length, 5);
  assert.equal(l.value(l.windowKey("global", "money", 86400, 1_800_000_000_000)), 85);
});
test("failed per-install reservation rolls the global debit back", t => {
  const l = ledger(t, 100, 20), now = 1_800_000_000_000;
  l.reserve(installation, ip, 17, now); assert.throws(() => l.reserve(installation, ip, 17, now));
  assert.equal(l.value(l.windowKey("global", "money", 86400, now)), 17);
});
test("UTC budget reset does not erase reservations made later that day", t => {
  const l = ledger(t, 30), before = Date.UTC(2026, 8, 23, 23, 59, 59), after = before + 2000;
  l.reserve(installation, ip, 30, before); l.reserve(installation, ip, 30, after);
  assert.throws(() => l.reserve(installation, ip, 1, after));
  assert.equal(l.value(l.windowKey("global", "money", 86400, before)), 30);
});
test("session leases enforce per-install concurrency and survive a ledger restart", t => {
  const l = ledger(t), now = 1_800_000_000_000;
  const a = l.acquire(installation, ip, "audio", 30000, now), b = l.acquire(installation, ip, "audio", 30000, now);
  assert.throws(() => l.acquire(installation, ip, "audio", 30000, now));
  const restarted = new Ledger(l.storage, l.limits);
  assert.throws(() => restarted.acquire(installation, ip, "audio", 30000, now));
  l.release(a); l.acquire(installation, ip, "audio", 30000, now);
  assert.equal(l.value(l.windowKey("global", "money", 86400, now)), 90000);
  l.release(b);
});
test("registration flood is bounded independently of paid calls", t => {
  const l = ledger(t), now = 1_800_000_000_000;
  for (let n = 0; n < 30; n++) l.register(ip, `${installation}${n}`, now);
  assert.throws(() => l.register(ip, `${installation}next`, now));
});
test("real app session configuration and one minimal retry are preserved", () => {
  const g = new AudioGuard(1000); const accepted = g.accept(JSON.stringify(session()), 1000);
  assert.deepEqual(accepted.event, session());
  const minimal = session(); minimal.session.audio.input.transcription = { model: "gpt-live-transcribe" };
  g.accept(JSON.stringify(minimal), 1001); assert.throws(() => g.accept(JSON.stringify(minimal), 1002));
});
test("audio session refuses tools, response generation, models and unsupported PCM", () => {
  for (const change of [s => { s.session.type = "realtime"; }, s => { s.session.audio.input.format.rate = 16000; },
    s => { s.session.audio.input.transcription.model = "other"; }, s => { s.session.tools = []; },
    s => { s.session.audio.input.turn_detection = { type: "server_vad" }; }, s => { s.session.audio.input.transcription.prompt = "x".repeat(4097); }]) {
    const s = session(); change(s); assert.throws(() => new AudioGuard().accept(JSON.stringify(s)));
  }
  const g = new AudioGuard(); g.accept(JSON.stringify(session()));
  for (const type of ["response.create", "conversation.item.create", "session.close"]) assert.throws(() => g.accept(JSON.stringify({ type })));
});
test("five-minute paced 4x recovery remains accepted with bounded total PCM", () => {
  const start = 1000, g = new AudioGuard(start); g.accept(JSON.stringify(session()), start);
  for (let i = 0; i < 3000; i++) g.accept(audio(4800), start + i * 25);
  assert.equal(g.bytes, 300 * 48000);
  assert.throws(() => g.accept(audio(4800), start + 75000));
});
test("handshake buffering accepts a full minute in a single bounded frame", () => {
  const g = new AudioGuard(1000); g.accept(JSON.stringify(session()), 1000);
  g.accept(audio(60 * 48000), 2000); assert.equal(g.bytes, 60 * 48000);
  assert.throws(() => g.accept(audio(120 * 48000), 2000));
});
test("audio cannot precede config, use malformed base64, odd PCM, or burst indefinitely", () => {
  assert.throws(() => new AudioGuard().accept(audio(4800)));
  for (const data of ["not base64!", "AAAA=", "AAAA", "", "a".repeat(LIMITS.messageBytes + 1)]) {
    const g = new AudioGuard(); g.accept(JSON.stringify(session()));
    assert.throws(() => g.accept(JSON.stringify({ type: "input_audio_buffer.append", audio: data })));
  }
  const g = new AudioGuard(1000); g.accept(JSON.stringify(session()), 1000);
  g.accept(audio(60 * 48000), 1000); assert.throws(() => g.accept(audio(4800), 1000));
});
test("empty commit, commit floods and repeated configuration cannot create unbounded work", () => {
  const g = new AudioGuard(1000); g.accept(JSON.stringify(session()), 1000);
  assert.throws(() => g.accept('{"type":"input_audio_buffer.commit"}', 1000));
  g.accept(audio(4800), 1000); g.accept('{"type":"input_audio_buffer.commit"}', 1000);
  g.accept(audio(4800), 1001); assert.throws(() => g.accept('{"type":"input_audio_buffer.commit"}', 1001));
  assert.throws(() => g.accept(JSON.stringify(session()), 1002));
  for (let i = 0; i < 4; i++) { g.accept(audio(4800), 3000 + i * 2000); g.accept('{"type":"input_audio_buffer.commit"}', 3000 + i * 2000); }
  g.accept(audio(4800), 12000); assert.throws(() => g.accept('{"type":"input_audio_buffer.commit"}', 12000));
});
test("message-rate limit stops tiny event floods", () => {
  const g = new AudioGuard(1000); g.accept(JSON.stringify(session()), 1000);
  let accepted = 0;
  for (let i = 0; i < 150; i++) { try { g.accept(audio(2), 1000); accepted++; } catch {} }
  assert(accepted <= 119);
});
test("relay queue closes before unbounded asynchronous work accumulates", async () => {
  const clients = new WebSocketPair(), providers = new WebSocketPair();
  let release = 0; const fake = { reserve() {}, storage: { async sync() { await new Promise(() => {}); } }, release() { release++; } };
  const stop = relayAudio(clients[1], providers[0], fake, "fixture", installation, ip);
  clients[0].accept(); providers[1].accept();
  clients[0].send(JSON.stringify(session()));
  for (let i = 0; i < 150; i++) { try { clients[0].send(audio(4800)); } catch {} }
  await new Promise(resolve => setTimeout(resolve, 30));
  assert.equal(release, 1); stop();
});

test("leases expire after their wall-time cap without erasing spend", t => {
  const l = ledger(t), now = 1_800_000_000_000;
  l.acquire(installation, ip, "audio", 30000, now); l.acquire(installation, ip, "audio", 30000, now);
  l.acquire(installation, ip, "audio", 30000, now + LIMITS.sessionSeconds * 1000 + 1);
  assert.equal(l.value(l.windowKey("global", "money", 86400, now)), 90000);
});
test("audio idle timeout closes both peers and releases its lease once", async t => {
  t.mock.timers.enable({ apis: ["Date", "setInterval"], now: 1_800_000_000_000 });
  const clients = new WebSocketPair(), providers = new WebSocketPair();
  let release = 0;
  relayAudio(clients[1], providers[0], { release() { release++; } }, "fixture", installation, ip);
  clients[0].accept(); providers[1].accept();
  t.mock.timers.tick(LIMITS.idleSeconds * 1000 + 1);
  assert.equal(release, 1);
  t.mock.timers.tick(LIMITS.idleSeconds * 1000); assert.equal(release, 1);
});
test("wall-time limit applies even when short audio keeps arriving", () => {
  const g = new AudioGuard(1000); g.accept(JSON.stringify(session()), 1000);
  assert.throws(() => g.accept(audio(4800), 1000 + LIMITS.sessionSeconds * 1000 + 1));
});
test("audio crossing midnight requires a reservation in the new UTC day", async t => {
  const before = Date.UTC(2026, 8, 23, 23, 59, 59);
  t.mock.timers.enable({ apis: ["Date", "setInterval"], now: before });
  const clients = new WebSocketPair(), providers = new WebSocketPair(), reservations = [], forwarded = [];
  const stop = relayAudio(clients[1], providers[0], {
    reserve(i, address, amount, now) { reservations.push({ amount, now }); },
    storage: { async sync() {} }, release() {},
  }, "fixture", installation, ip);
  clients[0].accept(); providers[1].accept(); providers[1].addEventListener("message", event => forwarded.push(JSON.parse(event.data)));
  clients[0].send(JSON.stringify(session())); clients[0].send(audio(4800));
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(reservations.length, 0);
  t.mock.timers.tick(2000); clients[0].send(audio(4800));
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.deepEqual(reservations, [{ amount: 30000, now: before + 2000 }]);
  assert.equal(forwarded.filter(e => e.type === "input_audio_buffer.append").length, 2); stop();
});

test("hour and day rate counters cannot collide at any epoch", t => {
  const l = ledger(t);
  assert.notEqual(l.windowKey(ip, "registrations", 3600, 1000), l.windowKey(ip, "registrations", 86400, 1000));
});
test("aborted audio request closes both sockets and releases its lease", async () => {
  const clients = new WebSocketPair(), providers = new WebSocketPair(), abort = new AbortController();
  let release = 0, providerClosed = false;
  relayAudio(clients[1], providers[0], { release() { release++; } }, "fixture", installation, ip, abort.signal);
  clients[0].accept(); providers[1].accept(); providers[1].addEventListener("close", () => { providerClosed = true; });
  abort.abort(); await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(release, 1); assert(providerClosed);
});
test("pending paid audio waits for durable reservation and cannot escape after disconnect", async t => {
  t.mock.timers.enable({ apis: ["Date", "setInterval"], now: 1_800_000_000_000 });
  const clients = new WebSocketPair(), providers = new WebSocketPair(), forwarded = [];
  let persist, reserved = 0, released = 0;
  const stop = relayAudio(clients[1], providers[0], {
    reserve() { reserved++; }, storage: { sync() { return new Promise(resolve => { persist = resolve; }); } }, release() { released++; },
  }, "fixture", installation, ip);
  clients[0].accept(); providers[1].accept(); providers[1].addEventListener("message", event => forwarded.push(JSON.parse(event.data)));
  clients[0].send(JSON.stringify(session())); clients[0].send(audio(60 * 48000));
  await new Promise(resolve => setTimeout(resolve, 20));
  t.mock.timers.tick(1000); clients[0].send(audio(4800));
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(reserved, 1); assert.equal(forwarded.length, 2); assert.equal(typeof persist, "function");
  stop(); persist(); await new Promise(resolve => setTimeout(resolve, 10));
  assert.equal(forwarded.length, 2); assert.equal(released, 1);
});
