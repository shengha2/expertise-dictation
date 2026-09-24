import test from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { Miniflare, Response as WorkerResponse, WebSocketPair } from "miniflare";
import { mintToken } from "../src/core.js";

const syntheticKey = "sk-synthetic-fixture-key-never-a-real-key";
const syntheticSecret = "synthetic-HMAC-fixture-secret-at-least-32-characters";
const installationID = "d3bb7d89-8d6b-4cc7-a755-0e457ef7d2ca";
const validChat = () => ({ model: "gpt-6-luna", reasoning_effort: "none", max_completion_tokens: 1000,
  messages: [{ role: "system", content: "Keep the supplied synthetic text." }, { role: "user", content: "Send the synthetic notes. 保留中文。" }] });
const validSession = () => ({ type: "session.update", session: { type: "transcription", audio: { input: {
  format: { type: "audio/pcm", rate: 24000 }, transcription: { model: "gpt-live-transcribe", languages: ["en", "zh-cn"], keywords: ["Expertise"], delay: "low" },
  noise_reduction: { type: "near_field" }, turn_detection: null,
} } } });
const append = (bytes = 4800) => JSON.stringify({ type: "input_audio_buffer.append", audio: Buffer.alloc(bytes).toString("base64") });

async function runtime(t, bindings = {}, outbound) {
  const calls = [];
  const mf = new Miniflare({
    modules: true, scriptPath: fileURLToPath(new URL("../src/worker.js", import.meta.url)),
    modulesRules: [{ type: "ESModule", include: ["**/*.js"] }],
    compatibilityDate: "2026-07-30",
    durableObjects: { GATEWAY: { className: "DictationGateway", useSQLite: true } },
    bindings: { OPENAI_API_KEY: syntheticKey, TOKEN_SIGNING_SECRET: syntheticSecret, DAILY_BUDGET_MICROUSD: "10000000", ...bindings },
    outboundService: async request => {
      // Every attempted outgoing request is intercepted. No network or API credit
      // is used by this suite, including unexpected hosts and redirect targets.
      calls.push({ url: request.url, authorization: request.headers.get("Authorization"), body: request.method === "POST" ? await request.json() : null });
      assert.equal(new URL(request.url).origin, "https://api.openai.com");
      assert.equal(request.headers.get("Authorization"), `Bearer ${syntheticKey}`);
      if (outbound) return await outbound(request, calls.at(-1));
      return WorkerResponse.json({ choices: [{ message: { content: "Synthetic result. 保留中文。" }, finish_reason: "stop" }] });
    },
  });
  t.after(() => mf.dispose());
  async function request(path, { token, body, headers = {}, ...rest } = {}) {
    return mf.dispatchFetch(`https://dictation.example${path}`, {
      ...rest, headers: { "CF-Connecting-IP": "192.0.2.1", ...(body ? { "Content-Type": "application/json" } : {}), ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers },
      ...(body ? { method: "POST", body: JSON.stringify(body) } : {}),
    });
  }
  async function register(id = installationID) {
    const response = await request("/v1/installations", { body: { installation_id: id } });
    assert.equal(response.status, 200, await response.clone().text());
    return (await response.json()).token;
  }
  return { mf, calls, request, register };
}
function messages(socket) {
  const pending = [], waiting = [];
  socket.addEventListener("message", event => { const item = JSON.parse(event.data); waiting.length ? waiting.shift()(item) : pending.push(item); });
  return async () => {
    if (pending.length) return pending.shift();
    let timer;
    try { return await Promise.race([new Promise(resolve => waiting.push(resolve)), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Timed out waiting for a local fixture message")), 2000); })]); }
    finally { clearTimeout(timer); }
  };
}

test("runtime: default zero budget and missing secrets refuse status and paid routes", async t => {
  for (const bindings of [{ DAILY_BUDGET_MICROUSD: "0" }, { OPENAI_API_KEY: "" }, { TOKEN_SIGNING_SECRET: "short" }]) {
    const r = await runtime(t, bindings);
    assert.equal((await r.request("/v1/status")).status, 503);
    assert.equal((await r.request("/v1/chat/completions", { body: validChat() })).status, 503);
    assert.equal(r.calls.length, 0);
  }
});
test("runtime: no-login registration and Chat contract work without exposing provider metadata", async t => {
  const r = await runtime(t);
  assert.deepEqual(await (await r.request("/v1/status")).json(), { ready: true });
  const token = await r.register(); assert(!token.includes(syntheticKey));
  const response = await r.request("/v1/chat/completions", { token, body: validChat() });
  assert.equal(response.status, 200, await response.clone().text());
  const result = await response.json();
  assert.equal(result.choices[0].message.content, "Synthetic result. 保留中文。");
  assert.equal(r.calls.length, 1); assert.equal(r.calls[0].body.store, false);
  assert.deepEqual(r.calls[0].body.messages, validChat().messages);
  assert(!JSON.stringify(result).includes(syntheticKey));
});
test("runtime: unauthorized, tampered, expired and unsafe requests make no upstream calls", async t => {
  const r = await runtime(t), token = await r.register();
  const expired = await mintToken(syntheticSecret, "a".repeat(64), Date.now() - 7200000);
  for (const bad of [null, "tampered", `${token}x`, expired.token]) {
    assert.equal((await r.request("/v1/chat/completions", { token: bad, body: validChat() })).status, 401);
  }
  for (const patch of [{ model: "other" }, { tools: [] }, { stream: true }, { max_completion_tokens: 999999 }]) {
    assert.equal((await r.request("/v1/chat/completions", { token, body: { ...validChat(), ...patch } })).status, 400);
  }
  assert.equal((await r.request("/v1/realtime?intent=realtime", { token, headers: { Upgrade: "websocket" } })).status, 404);
  assert.equal(r.calls.length, 0);
});
test("runtime: concurrent paid requests cannot cross the global SQLite budget", async t => {
  const r = await runtime(t, { DAILY_BUDGET_MICROUSD: "40000" });
  const token = await r.register();
  const results = await Promise.all(Array.from({ length: 12 }, () => r.request("/v1/chat/completions", { token, body: { ...validChat(), max_completion_tokens: 32768 } })));
  assert.equal(results.filter(x => x.status === 200).length, 1);
  assert(results.filter(x => x.status !== 200).every(x => x.status === 429));
  assert.equal(r.calls.length, 1);
  assert.equal((await r.request("/v1/status")).status, 503);
});
test("runtime: provider failures consume the reservation and return sanitized errors", async t => {
  const r = await runtime(t, { DAILY_BUDGET_MICROUSD: "40000" }, () => WorkerResponse.json({ error: { message: `${syntheticKey} ${syntheticSecret} private prompt` } }, { status: 500 }));
  const token = await r.register();
  const response = await r.request("/v1/chat/completions", { token, body: { ...validChat(), max_completion_tokens: 32768 } });
  assert.equal(response.status, 503);
  const text = await response.text(); assert(!text.includes(syntheticKey)); assert(!text.includes("private prompt"));
  assert.equal((await r.request("/v1/status")).status, 503);
  assert.equal(r.calls.length, 1);
});
test("runtime: redirects are refused without forwarding any credential", async t => {
  const r = await runtime(t, {}, () => new WorkerResponse(null, { status: 307, headers: { Location: "https://never-contact.example/collect" } }));
  const token = await r.register();
  assert.equal((await r.request("/v1/chat/completions", { token, body: validChat() })).status, 503);
  assert.equal(r.calls.length, 1);
});
test("runtime: WebSocket relay accepts native config/audio and returns only transcript fields", async t => {
  const received = [];
  const r = await runtime(t, {}, () => {
    const pair = new WebSocketPair(); pair[1].accept();
    pair[1].addEventListener("message", event => {
      const body = JSON.parse(event.data); received.push(body);
      if (body.type === "session.update") pair[1].send(JSON.stringify({ type: "session.updated", session: { debug_secret: syntheticKey } }));
      if (body.type === "input_audio_buffer.commit") pair[1].send(JSON.stringify({ type: "conversation.item.input_audio_transcription.completed", item_id: "item_fixture", transcript: "Hello. 你好。", private_metadata: syntheticSecret }));
    });
    return new WorkerResponse(null, { status: 101, webSocket: pair[0] });
  });
  const token = await r.register();
  const response = await r.request("/v1/realtime?intent=transcription", { token, headers: { Upgrade: "websocket" } });
  assert.equal(response.status, 101, response.status === 101 ? "" : await response.text());
  const socket = response.webSocket, next = messages(socket); socket.accept();
  socket.send(JSON.stringify(validSession()));
  const updated = await next(); assert.equal(updated.type, "session.updated"); assert(!JSON.stringify(updated).includes(syntheticKey));
  socket.send(append()); socket.send('{"type":"input_audio_buffer.commit"}');
  const completed = await next(); assert.equal(completed.transcript, "Hello. 你好。"); assert(!JSON.stringify(completed).includes(syntheticSecret));
  assert.deepEqual(received[0], validSession());
  assert.equal(received[1].type, "input_audio_buffer.append"); assert.equal(received[2].type, "input_audio_buffer.commit");
  socket.close();
});
test("runtime: unbudgeted second audio minute is never forwarded upstream", async t => {
  let appendedBytes = 0;
  const r = await runtime(t, { DAILY_BUDGET_MICROUSD: "30000" }, () => {
    const pair = new WebSocketPair(); pair[1].accept();
    pair[1].addEventListener("message", event => {
      const body = JSON.parse(event.data);
      if (body.type === "session.update") pair[1].send('{"type":"session.updated"}');
      if (body.type === "input_audio_buffer.append") appendedBytes += Buffer.from(body.audio, "base64").length;
    });
    return new WorkerResponse(null, { status: 101, webSocket: pair[0] });
  });
  const token = await r.register();
  const response = await r.request("/v1/realtime?intent=transcription", { token, headers: { Upgrade: "websocket" } });
  assert.equal(response.status, 101);
  const socket = response.webSocket, next = messages(socket); socket.accept();
  socket.send(JSON.stringify(validSession())); await next();
  socket.send(append(60 * 48000));
  await new Promise(resolve => setTimeout(resolve, 100));
  socket.send(append());
  const error = await next(); assert.equal(error.error.code, "usage_limit");
  assert.equal(appendedBytes, 60 * 48000);
});
test("runtime: audio generation events close the session without upstream forwarding", async t => {
  const received = [];
  const r = await runtime(t, {}, () => {
    const pair = new WebSocketPair(); pair[1].accept(); pair[1].addEventListener("message", event => received.push(JSON.parse(event.data)));
    return new WorkerResponse(null, { status: 101, webSocket: pair[0] });
  });
  const token = await r.register();
  const response = await r.request("/v1/realtime?intent=transcription", { token, headers: { Upgrade: "websocket" } });
  const socket = response.webSocket, next = messages(socket); socket.accept(); socket.send('{"type":"response.create"}');
  assert.equal((await next()).error.code, "invalid_request"); assert.equal(received.length, 0);
});

test("runtime: fake forwarded/internal IP headers cannot bypass trusted-IP registration limits", async t => {
  const r = await runtime(t);
  for (let i = 0; i < 30; i++) {
    const response = await r.request("/v1/installations", {
      body: { installation_id: crypto.randomUUID() },
      headers: { "X-Forwarded-For": `198.51.100.${i}`, "X-Verified-IP-Hash": crypto.randomUUID() },
    });
    assert.equal(response.status, 200);
  }
  const denied = await r.request("/v1/installations", {
    body: { installation_id: crypto.randomUUID() },
    headers: { "X-Forwarded-For": "203.0.113.50", "X-Verified-IP-Hash": "a".repeat(64) },
  });
  assert.equal(denied.status, 429); assert.equal(r.calls.length, 0);
});
test("runtime: concurrent audio session limit reserves before connecting the provider", async t => {
  const r = await runtime(t, {}, () => {
    const pair = new WebSocketPair(); pair[1].accept();
    return new WorkerResponse(null, { status: 101, webSocket: pair[0] });
  });
  const token = await r.register(), sockets = [];
  for (let i = 0; i < 2; i++) {
    const response = await r.request("/v1/realtime?intent=transcription", { token, headers: { Upgrade: "websocket" } });
    assert.equal(response.status, 101); response.webSocket.accept(); sockets.push(response.webSocket);
  }
  assert.equal((await r.request("/v1/realtime?intent=transcription", { token, headers: { Upgrade: "websocket" } })).status, 429);
  assert.equal(r.calls.length, 2); for (const socket of sockets) socket.close();
});

test("runtime: failed audio handshakes sanitize provider errors and release leases", async t => {
  const r = await runtime(t, {}, () => WorkerResponse.json({ error: { message: `${syntheticKey} provider account information` } }, { status: 401 }));
  const token = await r.register();
  for (let i = 0; i < 3; i++) {
    const response = await r.request("/v1/realtime?intent=transcription", { token, headers: { Upgrade: "websocket" } });
    assert.equal(response.status, 503);
    const body = await response.text(); assert(!body.includes(syntheticKey)); assert(!body.includes("account information"));
  }
  assert.equal(r.calls.length, 3);
});

test("runtime: plaintext HTTP never issues installation tokens", async t => {
  const r = await runtime(t);
  const response = await r.mf.dispatchFetch("http://dictation.example/v1/installations", {
    method: "POST", headers: { "CF-Connecting-IP": "192.0.2.1", "Content-Type": "application/json" },
    body: JSON.stringify({ installation_id: installationID }),
  });
  assert.equal(response.status, 400); assert.equal(r.calls.length, 0);
});
