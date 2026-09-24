# Expertise Dictation hosted service

This is the operator-funded, no-login gateway for the macOS app. **It is not deployed. The checked-in daily budget is zero, so the service is disabled.** Hosting access and the operator’s spending decision are still required. No API key or shared provider credential belongs in the app, DMG, repository, or public update feed.

## Run the local contract tests

Use Node 22.13 or later and pnpm. The tested runtime is Node 24.19.0 with the pinned stable Miniflare 4.20260730.0 / workerd 1.20260730.1.

```sh
cd service
pnpm install --frozen-lockfile --ignore-scripts
pnpm test
```

The platform-specific workerd package provides the local Worker runtime; no cloud login is needed. The unit fixtures use Node’s SQLite implementation. Runtime fixtures execute the real Worker and SQLite Durable Object locally through Miniflare. Every upstream request is intercepted by synthetic fixtures, including unexpected destinations. Tests require no provider credentials, perform no paid API calls, and do not deploy anything.

See [the recorded test output](evidence/local-tests.log) and [validation scope and source hashes](evidence/validation.json). The five-minute audio fixture checks the complete PCM allowance using virtual timestamps at 4× replay speed; it is not a real microphone or provider transcription trial. Local tests cannot prove deployed Cloudflare routing, the operator’s provider account access, internet reliability, or actual billing. A deployed synthetic end-to-end trial remains necessary before a public keyless app release.

## App contract

| Endpoint | Contract |
| --- | --- |
| `GET /v1/status` | `200 {"ready":true}` only when required secrets and budgets are configured, and at least one audio minute remains in the global reservation allowance. Otherwise a sanitized `503`. This is a configuration/budget check; it does not make a paid provider health probe. |
| `POST /v1/installations` | JSON `{"installation_id":"a random UUID"}`. Returns `{token, expires_at}` with a one-hour HMAC credential. No email, sign-in, hardware ID, or OpenAI key is requested. |
| `GET /v1/realtime?intent=transcription` | WebSocket upgrade with `Authorization: Bearer <installation token>`. Relays the allowed transcription events to the fixed OpenAI Realtime endpoint. |
| `POST /v1/chat/completions` | Bearer token plus the app’s two text messages (`system`, `user`), model `gpt-6-luna`, `reasoning_effort: "none"`, and `max_completion_tokens`. Returns the completed assistant text and finish reason in Chat Completions shape. |

Only the exact paths above are supported. Requests cannot select a provider origin. Redirects are refused. Chat is non-streaming, text-only, Standard processing, with `store: false`; tools, images, extra completions, arbitrary models and unbounded output are rejected. The system and user messages remain editable by the app, as required for its user-customizable rewrite prompt.

Audio is PCM16 mono at 24 kHz, fixed to `gpt-live-transcribe`. Allowed events are `session.update`, `input_audio_buffer.append`, `input_audio_buffer.commit`, and `input_audio_buffer.clear`. Session updates require transcription mode and disabled server turn detection. Prompt, language hints, keyword hints, delay, and near/far-field noise reduction are preserved within limits. Two configuration attempts are allowed before audio begins, so the app can retry without optional hints. No response-generation, tools, conversation writes, or arbitrary event forwarding is allowed. Item IDs and prior-item IDs are preserved for transcript ordering. Provider errors and session metadata are reconstructed instead of forwarded verbatim.

## Spending and abuse bounds

A **single SQLite Durable Object** named `global-budget-v1` owns all reservations, rate counters and active-session leases. Check-and-debit operations are synchronous transactions. Provider HTTP requests and newly reserved audio wait for durable storage synchronization. Failed calls, cancellation, disconnects and unused allowances are never refunded; this intentionally favors a conservative ceiling over maximum utilization.

Budgets use integer micro-US dollars: `1_000_000` = USD 1. Windows reset at midnight UTC. An audio stream crossing midnight reserves again in the new day before forwarding more audio. Concurrent sessions cannot independently reuse the same remaining global allowance. Do not create a second gateway namespace or reset its database to work around a limit: that would create an independent allowance.

| Configuration | Checked-in value | Meaning |
| --- | ---: | --- |
| `DAILY_BUDGET_MICROUSD` | `0` | Disabled. An **example only**, after operator approval, is `10000000` for USD 10 of reservations/day. |
| `INSTALL_DAILY_MICROUSD` | `5000000` | USD 5 of reservations per random installation/day. |
| `IP_DAILY_MICROUSD` | `10000000` | USD 10 of reservations per trusted client-IP pseudonym/day. |

Audio reserves **USD 0.03 per started minute**, beginning before the upstream socket opens. This is above the currently documented USD 0.017/minute rate for [GPT-Live-Transcribe](https://developers.openai.com/api/docs/models/gpt-live-transcribe). Every appended audio byte counts, including audio later cleared. Text reservations use the UTF-8 byte count as a conservative input-token bound, an additional 4,096-token framing allowance, the requested output-token maximum, **2×** the documented Standard input/output prices, and a USD 0.001 floor allowance. [GPT-6 Luna’s model page](https://developers.openai.com/api/docs/models/gpt-6-luna) currently lists USD 0.10/M input and USD 0.50/M output tokens and supports reasoning `none`.

These are conservative **reservations, not measured invoices or an unconditional billing guarantee**. Prices and provider behavior can change. The guard covers this gateway’s OpenAI work, not Cloudflare request/storage/duration charges, taxes, another application using the provider account, or a duplicated deployment. Review prices before enabling production. Use a dedicated provider project/key and configure the account’s available spending controls and alerts independently.

The anonymous UUID is not proof of a unique person: users can reinstall or attackers can rotate IDs. Per-IP quotas slow that behavior, while the global allowance limits total admitted provider work. Distributed abuse can still exhaust the allowance and affect legitimate users. These are pilot limits; a wider launch needs actual load and abuse testing.

## Fixed pilot limits

| Area | Limit |
| --- | --- |
| Public ingress | 120 requests/minute/IP; 3,000/minute globally |
| Registration | 30/hour/IP, 240/day/IP; 8/hour/installation; 5,000/day globally |
| Audio concurrency | 2 sessions/installation, 4/IP, **4 globally**, allowing current/finishing segment overlap |
| Text concurrency | 2 requests/installation, 4/IP, 8 globally |
| Session starts | Audio 12/minute/installation; text 30/minute/installation; each 900/day/installation |
| Audio session | 300 seconds of PCM, 480 seconds wall time; 150-second input-idle timeout allows a slow final transcript |
| Audio pacing | 60-second initial buffered allowance plus 8× elapsed time; the app’s 4× saved-recording replay is supported |
| Incoming WebSocket data | 4 MiB/message, 4 MiB queued/session, at most 128 queued callbacks; 80 events/second with burst 120; 16,000 events/session |
| Commits | At least 100 ms of buffered audio; at most 5/session, at least 1 second apart |
| Provider output | 512 KiB/event, 2 MiB/session, at most 10,000 events/session |
| Text | 128 KiB request body; 32,768 output tokens; 512 KiB provider response |
| Timeouts | Request-body read 10 s, upstream chat headers 60 s/body 15 s, audio handshake 10 s |

The app rotates durable provider segments every 45–60 seconds, so a longer dictation uses bounded sessions. The session limit is not the app’s total recording limit. If the allowance or service fails, the app must preserve audio locally and offer retry/copy. Accounts behind the same public IP share IP limits. Concurrency and queue caps also keep memory bounded for this initial single-object service; raising them requires load testing and revisiting memory limits.

## Deployment handoff — still pending

1. Obtain the operator’s Cloudflare account/host choice and explicit provider-budget value. Keep the current zero budget until that is decided.
2. Use an isolated provider project with access to `gpt-live-transcribe` and `gpt-6-luna`. Store `OPENAI_API_KEY` as a Cloudflare Worker secret. Generate an independent random signing secret of at least 32 bytes and store it as `TOKEN_SIGNING_SECRET`. Enter secrets through the platform’s secret prompt/store, never as public variables or source literals.
3. Deploy `wrangler.toml` with its SQLite Durable Object migration, preserving the same namespace for future updates. Add the approved HTTPS custom-domain route. `workers_dev` and preview URLs are disabled by default, so the template creates no intentional public testing endpoint.
4. Configure the approved daily reservation budget. If the choice is USD 10/day, the value is `10000000`; this README does not authorize or apply it.
5. Keep request/body/debug logging disabled. Verify the production edge overwrites `CF-Connecting-IP`; the code ignores forwarded/internal client headers and creates its own HMAC IP pseudonym. Do not expose the Durable Object through another public binding or add an origin that trusts raw client-supplied IP headers.
6. Run production contract checks with synthetic, nonpersonal text/audio: registration, short dictation, mixed-language hints, a long segmented recording, saved-audio replay, request cancellation and forced provider failure. Confirm the provider dashboard cost against reservations and the absence of request content in logs.
7. Only then embed the approved **public HTTPS origin** in the app’s `ExpertiseServiceURL`, rebuild, run the app tests, sign/notarize and distribute. No provider secret is embedded.

To stop new use, set the daily budget to zero and deploy. Existing admitted work may finish within its reserved allowance and bounded session lifetime. For an urgent provider-side stop, revoke the dedicated provider key. Rotating the HMAC secret invalidates existing installation tokens; clients can register again. Counters and leases remain in SQLite so a restart cannot forget spending.

## Data handling

Only HMAC pseudonyms, numeric counters and expiring leases are stored by this code. Raw IPs, UUIDs, audio, transcript text and prompts are not stored in the Durable Object. Counter rows become eligible for deletion within two rate-window lengths (up to 48 hours) and are removed during later traffic; leases expire in at most eight minutes. Cloudflare backups and its platform metadata policies apply separately. Audio/text still pass through Cloudflare and OpenAI to process the user’s request; do not claim zero retention for those providers without the corresponding account arrangements.

There are no `console` transcript/request logs or provider-error body echoes. Worker observability is disabled in the template. This does not configure an operator’s separate Cloudflare account-wide logging products or OpenAI data settings; review those before launch.

Implementation references: [OpenAI realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription), [Cloudflare SQLite transactions and output gates](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/), and [Cloudflare WebSockets](https://developers.cloudflare.com/workers/runtime-apis/websockets/).

## Native Swift contract fixture (local only)

```sh
node service/test/native-fixture.mjs
```

Run that command from the repository root. It binds only to `127.0.0.1` on an automatically chosen port, prints one JSON ready line containing the `http://127.0.0.1:PORT` origin, and shuts down after five minutes or SIGINT/SIGTERM. The Swift CLI contract test can use this origin through its explicit loopback-only test injection. `GET /__fixture/status` reports synthetic provider-call counts without text, credentials, tokens, or installation IDs.

This fixture is **not deployable service configuration**. Its test-only adapter supplies a synthetic edge IP and rewrites loopback HTTP into the production handler’s expected HTTPS request. The production Worker is unchanged and remains HTTPS-only. The upstreams are fully intercepted: committed audio returns `Gateway fixture speech. 保留中文。`; Chat completion returns `Gateway fixture cleaned text. 保留中文。`. No environment credentials are read and no OpenAI request can leave this fixture. The purpose is Swift/Worker authentication, WebSocket framing, transcript event ordering, cleanup response parsing and cancellation compatibility—not transcription quality or a production readiness demonstration.
