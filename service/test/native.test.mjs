import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { fileURLToPath } from "node:url";

test("native fixture: bounded loopback server serves auth and cleanup with no real upstream", async () => {
  const child = spawn(process.execPath, [fileURLToPath(new URL("native-fixture.mjs", import.meta.url))], { stdio: ["ignore", "pipe", "pipe"] });
  let pending = "", timer;
  try {
    const ready = await Promise.race([
      new Promise((resolve, reject) => {
        child.stdout.on("data", bytes => { pending += bytes; if (pending.includes("\n")) resolve(JSON.parse(pending.split("\n")[0])); });
        child.on("exit", code => reject(new Error(`Fixture exited with code ${code}`)));
      }),
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Fixture startup timed out")), 10000); }),
    ]);
    clearTimeout(timer);
    assert.equal(ready.fixture, true); assert.match(ready.origin, /^http:\/\/127\.0\.0\.1:\d+$/);
    assert.equal(ready.expires_in_ms, 300000);
    assert.deepEqual(await (await fetch(`${ready.origin}/v1/status`)).json(), { ready: true });
    const registration = await fetch(`${ready.origin}/v1/installations`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ installation_id: crypto.randomUUID() }),
    });
    assert.equal(registration.status, 200);
    const { token } = await registration.json();
    const response = await fetch(`${ready.origin}/v1/chat/completions`, {
      method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify({ model: "gpt-6-luna", reasoning_effort: "none", max_completion_tokens: 100,
        messages: [{ role: "system", content: "Synthetic fixture" }, { role: "user", content: "Synthetic fixture" }] }),
    });
    assert.equal(response.status, 200);
    assert.equal((await response.json()).choices[0].message.content, "Gateway fixture cleaned text. 保留中文。");
    const stats = await (await fetch(`${ready.origin}/__fixture/status`)).json();
    assert.equal(stats.chatRequests, 1); assert.equal(stats.unexpectedUpstreams, 0);
  } finally {
    clearTimeout(timer);
    if (child.exitCode === null) { child.kill("SIGTERM"); await once(child, "exit"); }
  }
});
