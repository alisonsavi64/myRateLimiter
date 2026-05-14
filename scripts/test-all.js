#!/usr/bin/env node
// test-all.js — Rate Limiter integration tests
// Run from repo root: node scripts/test-all.js
//
// Requirements: Node 18+, Docker running, stack up:
//   cd nginx-imp && docker compose up --build
//
// No npm dependencies — uses built-in fetch + crypto.

const { createHmac } = require("crypto");
const { execSync } = require("child_process");

// ── Colors ───────────────────────────────────────────────────────────────────

const c = {
  reset:  "\x1b[0m",
  green:  "\x1b[32m",
  red:    "\x1b[31m",
  yellow: "\x1b[33m",
  cyan:   "\x1b[36m",
  gray:   "\x1b[90m",
};

// ── State ─────────────────────────────────────────────────────────────────────

let passed = 0;
let failed = 0;

// ── Helpers ───────────────────────────────────────────────────────────────────

function section(title) {
  console.log(`\n${c.yellow}━━━ ${title} ━━━${c.reset}`);
}

function assert(label, actual, expected) {
  if (String(actual) === String(expected)) {
    console.log(`${c.green}  [PASS]${c.reset} ${label} → ${actual}`);
    passed++;
  } else {
    console.log(`${c.red}  [FAIL]${c.reset} ${label} → got ${actual}, want ${expected}`);
    failed++;
  }
}

function info(msg) {
  console.log(`${c.gray}  [INFO] ${msg}${c.reset}`);
}

function makeToken(userId, userType, secret = "mysecret", exp = 9999999999) {
  const header  = Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString("base64url");
  const payload = Buffer.from(JSON.stringify({ sub: userId, user_type: userType, exp })).toString("base64url");
  const input   = `${header}.${payload}`;
  const sig     = createHmac("sha256", secret).update(input).digest("base64url");
  return `Bearer ${input}.${sig}`;
}

async function req(url, auth = null) {
  const headers = auth ? { Authorization: auth } : {};
  try {
    const res = await fetch(url, { headers });
    return {
      status:    res.status,
      limit:     res.headers.get("x-ratelimit-limit"),
      remaining: res.headers.get("x-ratelimit-remaining"),
      reset:     res.headers.get("x-ratelimit-reset"),
      retryAfter:res.headers.get("retry-after"),
    };
  } catch {
    return { status: 0 };
  }
}

function flushRedis() {
  try {
    execSync("docker exec redis-master redis-cli FLUSHALL", { stdio: "pipe" });
    info("Redis flushed — clean slate for this section");
  } catch {
    info("Redis flush skipped (container not reachable)");
  }
}

function showRL(r) {
  if (r.limit)     console.log(`${c.cyan}        X-RateLimit-Limit:     ${r.limit}${c.reset}`);
  if (r.remaining) console.log(`${c.cyan}        X-RateLimit-Remaining: ${r.remaining}${c.reset}`);
  if (r.reset)     console.log(`${c.cyan}        X-RateLimit-Reset:      ${r.reset}${c.reset}`);
  if (r.retryAfter)console.log(`${c.cyan}        Retry-After:            ${r.retryAfter}${c.reset}`);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

async function main() {
  // Tokens — generated locally, no Docker needed
  section("Generating JWT tokens");
  const basicToken   = makeToken("user-123",     "basic");
  const premiumToken = makeToken("user-premium",  "premium");
  const adminToken   = makeToken("user-admin",    "admin");
  info(`basic:   ${basicToken.slice(0, 60)}...`);
  info(`premium: ${premiumToken.slice(0, 60)}...`);
  info(`admin:   ${adminToken.slice(0, 60)}...`);

  // ── 1: NGINX (:80) — IP rate limiting, no auth ──────────────────────────────

  section("1 · NGINX (:80) — IP rate limiting, no auth");
  flushRedis();

  let r = await req("http://localhost/health");
  assert("GET /health → 200", r.status, 200);

  r = await req("http://localhost/");
  info(`GET / → ${r.status} (passes through NGINX before limit)`);

  info("Running 125 requests to trigger 429 (limit = 120)...");
  let first429nginx = 0;
  for (let i = 1; i <= 125; i++) {
    const s = (await req("http://localhost/")).status;
    if (s === 429 && first429nginx === 0) first429nginx = i;
  }
  assert("429 triggered after 120 requests", first429nginx > 0 ? "true" : "false", "true");
  if (first429nginx) info(`First 429 at request #${first429nginx}`);

  // ── 2: Go Proxy (:8080) — unauthenticated (anonymous = basic) ───────────────

  section("2 · Go Proxy (:8080) — unauthenticated (anonymous user)");
  flushRedis();

  r = await req("http://localhost:8080/health");
  assert("GET /health → 200", r.status, 200);
  assert("/health has no X-RateLimit headers", r.limit === null ? "no-headers" : "has-headers", "no-headers");

  r = await req("http://localhost:8080/");
  assert("GET / → 200 (echo mode)", r.status, 200);
  assert("X-RateLimit-Limit: 60 (default basic)", r.limit, "60");
  showRL(r);

  r = await req("http://localhost:8080/api/search");
  assert("GET /api/search → 200", r.status, 200);
  assert("X-RateLimit-Limit: 20 (route override for basic)", r.limit, "20");
  showRL(r);

  // ── 3: Go Proxy (:8080) — basic user, trigger 429 ───────────────────────────

  section("3 · Go Proxy (:8080) — basic user (limit: 20/min on /api/search)");
  flushRedis();

  r = await req("http://localhost:8080/api/search", basicToken);
  assert("First request → 200", r.status, 200);
  assert("X-RateLimit-Limit: 20", r.limit, "20");
  showRL(r);

  info("Running 22 requests to trigger 429 (limit = 20, 1 already sent)...");
  let first429basic = 0;
  let last429r = null;
  for (let i = 2; i <= 22; i++) {
    r = await req("http://localhost:8080/api/search", basicToken);
    if (r.status === 429 && first429basic === 0) {
      first429basic = i;
      last429r = r;
    }
  }
  assert("429 triggered after 20 requests", first429basic > 0 ? "true" : "false", "true");
  if (first429basic) {
    info(`First 429 at request #${first429basic}`);
    info("429 response headers:");
    showRL(last429r);
  }

  // ── 4: Go Proxy (:8080) — premium user, higher limits ───────────────────────

  section("4 · Go Proxy (:8080) — premium user (limit: 200/min on /api/search)");
  flushRedis();

  r = await req("http://localhost:8080/api/search", premiumToken);
  assert("GET /api/search → 200", r.status, 200);
  assert("X-RateLimit-Limit: 200 (premium route override)", r.limit, "200");
  showRL(r);

  r = await req("http://localhost:8080/api/export", premiumToken);
  assert("GET /api/export → 200", r.status, 200);
  assert("X-RateLimit-Limit: 50 (premium export override)", r.limit, "50");
  showRL(r);

  // ── 5: Go Proxy (:8080) — admin user, unlimited ──────────────────────────────

  section("5 · Go Proxy (:8080) — admin user (unlimited)");
  flushRedis();

  r = await req("http://localhost:8080/api/search", adminToken);
  assert("GET /api/search → 200", r.status, 200);
  assert("No X-RateLimit headers (unlimited)", r.limit === null ? "no-headers" : "has-headers", "no-headers");
  info("Admin user bypasses rate limiting entirely");

  // ── 6: Lambda Authorizer (:3000) — serverless-offline ───────────────────────

  section("6 · Lambda Authorizer (:3000) — serverless-offline");
  flushRedis();

  r = await req("http://localhost:3000/health");
  info(`GET /health → ${r.status} (no authorizer on /health if not configured, or 403 if authorizer covers all routes)`);

  r = await req("http://localhost:3000/api/test", basicToken);
  assert("GET /api/test with basic JWT → 200", r.status, 200);

  r = await req("http://localhost:3000/api/test", adminToken);
  assert("GET /api/test with admin JWT → 200 (unlimited)", r.status, 200);

  r = await req("http://localhost:3000/api/test");
  assert("GET /api/test without JWT → 401 or 403 (denied)", String(r.status === 401 || r.status === 403), "true");

  info("Running 65 requests to trigger rate limit (basic limit = 60)...");
  flushRedis();
  r = await req("http://localhost:3000/api/test", basicToken);
  let first429lambda = 0;
  for (let i = 2; i <= 65; i++) {
    const s = (await req("http://localhost:3000/api/test", basicToken)).status;
    // serverless-offline returns 403 on authorizer deny; AWS returns 429 via Gateway Response
    if ((s === 429 || s === 403) && first429lambda === 0) first429lambda = i;
  }
  assert("Rate limit enforced after 60 requests (403 local / 429 in AWS)", first429lambda > 0 ? "true" : "false", "true");
  if (first429lambda) info(`First blocked at request #${first429lambda}`);

  // ── Summary ──────────────────────────────────────────────────────────────────

  section("Summary");
  const total = passed + failed;
  const color = failed === 0 ? c.green : c.yellow;
  console.log(`${color}  Passed: ${passed} / ${total}${c.reset}`);
  if (failed > 0) {
    console.log(`${c.red}  Failed: ${failed} / ${total}${c.reset}`);
  }
  console.log();

  process.exit(failed > 0 ? 1 : 0);
}

main().catch(err => {
  console.error(`${c.red}Fatal: ${err.message}${c.reset}`);
  process.exit(1);
});
