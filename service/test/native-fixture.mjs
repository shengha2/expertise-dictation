// Bounded loopback fixture for the Swift --hosted-selftest contract test.
// All provider calls are intercepted. No environment credentials are read.
import { fileURLToPath } from "node:url";
import { Miniflare, Response, WebSocketPair } from "miniflare";

export const TRANSCRIPT = "Gateway fixture speech. 保留中文。";
export const CLEANUP = "Gateway fixture cleaned text. 保留中文。";
const lifetimeMS = 300000;
const stats = { fixture: true, upstreamConnections: 0, chatRequests: 0, audioBytes: 0, commits: 0, closedUpstreams: 0, unexpectedUpstreams: 0 };
const mf = new Miniflare({
  host: "127.0.0.1", port: 0, modules: true,
  scriptPath: fileURLToPath(new URL("native-worker.mjs", import.meta.url)),
  modulesRules: [{ type: "ESModule", include: ["**/*.js", "**/*.mjs"] }],
  compatibilityDate: "2026-07-30",
  durableObjects: { GATEWAY: { className: "DictationGateway", useSQLite: true } },
  bindings: {
    FIXTURE_ONLY: "local-synthetic-upstream",
    OPENAI_API_KEY: "synthetic-native-fixture-provider-placeholder",
    TOKEN_SIGNING_SECRET: "synthetic-native-fixture-signing-placeholder-at-least-32-characters",
    DAILY_BUDGET_MICROUSD: "10000000",
  },
  serviceBindings: { FIXTURE_STATUS: () => Response.json(stats) },
  outboundService: async request => {
    const url = new URL(request.url);
    if (url.origin !== "https://api.openai.com") {
      stats.unexpectedUpstreams++;
      return Response.json({ error: { message: "Unexpected fixture destination" } }, { status: 502 });
    }
    if (url.pathname === "/v1/chat/completions" && request.method === "POST") {
      stats.chatRequests++;
      return Response.json({ choices: [{ message: { role: "assistant", content: CLEANUP }, finish_reason: "stop" }] });
    }
    if (url.pathname !== "/v1/realtime" || url.search !== "?intent=transcription") {
      stats.unexpectedUpstreams++;
      return new Response(null, { status: 404 });
    }
    stats.upstreamConnections++;
    const pair = new WebSocketPair(); pair[1].accept();
    pair[1].addEventListener("message", event => {
      const body = JSON.parse(event.data);
      if (body.type === "session.update") pair[1].send('{"type":"session.updated","session":{"type":"transcription"}}');
      if (body.type === "input_audio_buffer.append") stats.audioBytes += Buffer.from(body.audio, "base64").length;
      if (body.type === "input_audio_buffer.commit") {
        stats.commits++;
        pair[1].send(JSON.stringify({ type: "input_audio_buffer.committed", item_id: "item_native_fixture", previous_item_id: null }));
        pair[1].send(JSON.stringify({ type: "conversation.item.input_audio_transcription.delta", item_id: "item_native_fixture", delta: "Gateway fixture speech. " }));
        pair[1].send(JSON.stringify({ type: "conversation.item.input_audio_transcription.completed", item_id: "item_native_fixture", transcript: TRANSCRIPT }));
      }
    });
    pair[1].addEventListener("close", () => { stats.closedUpstreams++; });
    return new Response(null, { status: 101, webSocket: pair[0] });
  },
});
let stopping = false;
async function stop() {
  if (stopping) return; stopping = true; clearTimeout(expiry);
  await mf.dispose(); process.exit(0);
}
const expiry = setTimeout(stop, lifetimeMS);
process.once("SIGTERM", stop); process.once("SIGINT", stop);
try {
  const origin = (await mf.ready).origin;
  process.stdout.write(`${JSON.stringify({ ready: true, fixture: true, origin, expires_in_ms: lifetimeMS })}\n`);
} catch {
  process.stderr.write("Local synthetic gateway fixture could not start.\n");
  await mf.dispose(); process.exit(1);
}
