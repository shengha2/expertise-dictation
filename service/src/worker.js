import { DurableObject } from "cloudflare:workers";
import { config, json, errorResponse, unavailable, ServiceError, LIMITS, digest, installationID, mintToken, verifyToken, readJSON, validateChat, safeChatResponse } from "./core.js";
import { Ledger } from "./ledger.js";
import { relayAudio } from "./audio.js";

export default {
  async fetch(request, env) {
    try {
      if (new URL(request.url).protocol !== "https:") throw new ServiceError(400, "https_required", "Use the secure HTTPS dictation service address.");
      const limits = config(env);
      if (!limits.configured || !limits.budget || !limits.installationBudget || !limits.ipBudget) throw unavailable();
      // Cloudflare overwrites this header on public ingress. Ignore X-Forwarded-For
      // and every client-supplied internal header. Local fixtures use a synthetic IP.
      const clientIP = request.headers.get("CF-Connecting-IP");
      if (!clientIP || clientIP.length > 64 || !/^[0-9a-fA-F:.]+$/.test(clientIP)) throw unavailable();
      const hash = await digest(env.TOKEN_SIGNING_SECRET, "ip", clientIP);
      const headers = new Headers();
      for (const name of ["Authorization", "Content-Type", "Content-Length", "Upgrade"]) {
        const value = request.headers.get(name);
        if (value !== null) headers.set(name, value);
      }
      headers.set("X-Verified-IP-Hash", hash);
      const forwarded = new Request(request, { headers });
      return await env.GATEWAY.get(env.GATEWAY.idFromName("global-budget-v1")).fetch(forwarded);
    } catch (error) { return errorResponse(error); }
  },
};

export class DictationGateway extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env); this.env = env; this.limits = config(env); this.ledger = new Ledger(ctx.storage, this.limits);
  }
  async fetch(request) {
    try {
      if (!this.limits.configured || !this.limits.budget) throw unavailable();
      const ip = request.headers.get("X-Verified-IP-Hash");
      if (!/^[a-f0-9]{64}$/.test(ip ?? "")) throw unavailable();
      this.ledger.ingress(ip);
      const url = new URL(request.url);
      if (url.pathname === "/v1/status" && request.method === "GET" && !url.search) {
        if (!this.ledger.ready()) throw unavailable();
        return json({ ready: true });
      }
      if (url.pathname === "/v1/installations" && request.method === "POST" && !url.search) {
        if (!this.ledger.ready()) throw unavailable();
        this.requireJSON(request);
        const body = await readJSON(request.body, 1024);
        const installation = await digest(this.env.TOKEN_SIGNING_SECRET, "installation", installationID(body));
        this.ledger.register(ip, installation);
        return json(await mintToken(this.env.TOKEN_SIGNING_SECRET, installation));
      }
      const installation = await verifyToken(this.env.TOKEN_SIGNING_SECRET, request.headers.get("Authorization"));
      if (url.pathname === "/v1/chat/completions" && request.method === "POST" && !url.search) return await this.chat(request, installation, ip);
      if (url.pathname === "/v1/realtime" && request.method === "GET" && url.search === "?intent=transcription") return await this.audio(request, installation, ip);
      throw new ServiceError(404, "not_found", "This dictation endpoint is not available.");
    } catch (error) { return errorResponse(error); }
  }
  requireJSON(request) {
    if (request.headers.get("Content-Type")?.split(";")[0].trim().toLowerCase() !== "application/json") throw new ServiceError();
    const size = request.headers.get("Content-Length");
    if (size && (!/^\d+$/.test(size) || Number(size) > LIMITS.requestBytes)) throw new ServiceError(413, "too_large", "This dictation section is too large.");
  }
  async chat(request, installation, ip) {
    this.requireJSON(request);
    const checked = validateChat(await readJSON(request.body, LIMITS.requestBytes));
    const lease = this.ledger.acquire(installation, ip, "text", checked.reserve);
    try {
      await this.ctx.storage.sync();
      request.signal.throwIfAborted();
      const response = await fetch("https://api.openai.com/v1/chat/completions", {
        method: "POST", redirect: "manual", signal: AbortSignal.any([request.signal, AbortSignal.timeout(60000)]),
        headers: { "Content-Type": "application/json", "Authorization": `Bearer ${this.env.OPENAI_API_KEY}` },
        body: JSON.stringify(checked.request),
      });
      if (response.status !== 200) { response.body?.cancel().catch(() => {}); throw unavailable(); }
      const result = safeChatResponse(await readJSON(response.body, LIMITS.responseBytes, 15000));
      return json(result);
    } finally { this.ledger.release(lease); }
  }
  async audio(request, installation, ip) {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") throw new ServiceError(426, "upgrade_required", "A WebSocket connection is required for dictation.");
    const lease = this.ledger.acquire(installation, ip, "audio", LIMITS.audioMinuteMicroUSD);
    let upstream;
    try {
      await this.ctx.storage.sync();
      request.signal.throwIfAborted();
      const response = await fetch("https://api.openai.com/v1/realtime?intent=transcription", {
        redirect: "manual", signal: AbortSignal.any([request.signal, AbortSignal.timeout(10000)]),
        headers: { "Upgrade": "websocket", "Authorization": `Bearer ${this.env.OPENAI_API_KEY}` },
      });
      upstream = response.webSocket;
      if (response.status !== 101 || !upstream) { response.body?.cancel().catch(() => {}); throw unavailable(); }
      request.signal.throwIfAborted();
      const pair = new WebSocketPair();
      relayAudio(pair[1], upstream, this.ledger, lease, installation, ip, request.signal);
      return new Response(null, { status: 101, webSocket: pair[0] });
    } catch (error) {
      try { upstream?.accept(); } catch {}
      try { upstream?.close(1011, "Session stopped"); } catch {}
      this.ledger.release(lease); throw error;
    }
  }
}
