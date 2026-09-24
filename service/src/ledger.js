import { quotaError, LIMITS } from "./core.js";

/** Every check and debit happens in a synchronous SQLite transaction. No network
 * operation is issued until the reservation is durably committed by the DO. */
export class Ledger {
  constructor(storage, limits) {
    this.storage = storage; this.sql = storage.sql; this.limits = limits; this.lastSweep = 0;
    this.sql.exec("CREATE TABLE IF NOT EXISTS counters (k TEXT PRIMARY KEY, value INTEGER NOT NULL, expires INTEGER NOT NULL)");
    this.sql.exec("CREATE TABLE IF NOT EXISTS leases (id TEXT PRIMARY KEY, installation TEXT NOT NULL, ip TEXT NOT NULL, kind TEXT NOT NULL, expires INTEGER NOT NULL)");
    this.sql.exec("CREATE INDEX IF NOT EXISTS lease_expiry ON leases(expires)");
  }
  value(key) { return this.sql.exec("SELECT value FROM counters WHERE k = ?", key).toArray()[0]?.value ?? 0; }
  windowKey(scope, label, seconds, now) { return `${scope}:${label}:${seconds}:${Math.floor(now / (seconds * 1000))}`; }
  charge(scope, label, seconds, amount, limit, now) {
    return { key: this.windowKey(scope, label, seconds, now), amount, limit, expires: now + seconds * 2000 };
  }
  consume(charges, now = Date.now()) {
    this.storage.transactionSync(() => {
      if (now - this.lastSweep > 60000) {
        this.sql.exec("DELETE FROM counters WHERE expires < ?", now);
        this.sql.exec("DELETE FROM leases WHERE expires <= ?", now);
        this.lastSweep = now;
      }
      for (const c of charges) {
        if (!Number.isSafeInteger(c.amount) || c.amount < 0 || this.value(c.key) + c.amount > c.limit) throw quotaError();
      }
      for (const c of charges) this.sql.exec("INSERT INTO counters(k,value,expires) VALUES(?,?,?) ON CONFLICT(k) DO UPDATE SET value=value+excluded.value, expires=excluded.expires", c.key, c.amount, c.expires);
    });
  }
  ready(now = Date.now()) { return this.limits.budget - this.value(this.windowKey("global", "money", 86400, now)) >= LIMITS.audioMinuteMicroUSD; }
  ingress(ip, now = Date.now()) {
    this.consume([this.charge(`ip:${ip}`, "requests", 60, 1, 120, now), this.charge("global", "requests", 60, 1, 3000, now)], now);
  }
  register(ip, installation, now = Date.now()) {
    this.consume([
      this.charge(`ip:${ip}`, "registrations", 3600, 1, 30, now),
      this.charge(`ip:${ip}`, "registrations", 86400, 1, 240, now),
      this.charge(`installation:${installation}`, "registrations", 3600, 1, 8, now),
      this.charge("global", "registrations", 86400, 1, 5000, now),
    ], now);
  }
  reserve(installation, ip, microUSD, now = Date.now()) {
    this.consume([
      this.charge("global", "money", 86400, microUSD, this.limits.budget, now),
      this.charge(`installation:${installation}`, "money", 86400, microUSD, this.limits.installationBudget, now),
      this.charge(`ip:${ip}`, "money", 86400, microUSD, this.limits.ipBudget, now),
    ], now);
  }
  acquire(installation, ip, kind, reserve, now = Date.now()) {
    const id = crypto.randomUUID();
    this.storage.transactionSync(() => {
      this.sql.exec("DELETE FROM leases WHERE expires <= ?", now);
      const count = (where, ...args) => this.sql.exec(`SELECT count(*) AS n FROM leases WHERE kind = ? ${where}`, kind, ...args).toArray()[0].n;
      if (count("") >= (kind === "audio" ? 4 : 8) || count("AND installation = ?", installation) >= 2 || count("AND ip = ?", ip) >= 4) throw quotaError();
      this.reserve(installation, ip, reserve, now);
      this.consume([
        this.charge(`installation:${installation}`, `${kind}-starts`, 60, 1, kind === "audio" ? 12 : 30, now),
        this.charge(`installation:${installation}`, `${kind}-starts`, 86400, 1, 900, now),
      ], now);
      const seconds = kind === "audio" ? LIMITS.sessionSeconds : 90;
      this.sql.exec("INSERT INTO leases VALUES(?,?,?,?,?)", id, installation, ip, kind, now + seconds * 1000);
    });
    return id;
  }
  release(id) { this.sql.exec("DELETE FROM leases WHERE id = ?", id); }
}
