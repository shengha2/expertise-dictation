// TEST ONLY. This adapter must never be deployed. The production entry point in
// wrangler.toml remains src/worker.js and enforces HTTPS plus Cloudflare ingress.
import production, { DictationGateway } from "../src/worker.js";
export { DictationGateway };
let rejectNextHandshake = false;
let registrations = 0;
let rejectedHandshakes = 0;
export default {
  async fetch(request, env) {
    if (env.FIXTURE_ONLY !== "local-synthetic-upstream") return new Response(null, { status: 503 });
    const url = new URL(request.url);
    if (url.pathname === "/__fixture/status") {
      const status = await env.FIXTURE_STATUS.fetch("https://fixture.invalid/status");
      return Response.json({ ...(await status.json()), registrations, rejectedHandshakes });
    }
    if (url.pathname === "/__fixture/reject-next-handshake" && request.method === "POST") {
      rejectNextHandshake = true;
      return Response.json({ fixture: true, armed: true });
    }
    if (url.pathname === "/v1/installations") registrations++;
    if (url.pathname === "/v1/realtime" && rejectNextHandshake) {
      rejectNextHandshake = false;
      rejectedHandshakes++;
      return Response.json({ error: { code: "unauthorized", message: "Synthetic token rejection." } }, { status: 401 });
    }
    const headers = new Headers(request.headers);
    headers.set("CF-Connecting-IP", "192.0.2.12");
    url.protocol = "https:"; url.hostname = "fixture.invalid"; url.port = "";
    const forwarded = new Request(new Request(url, request), { headers });
    return production.fetch(forwarded, env);
  },
};
