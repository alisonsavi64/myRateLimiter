# application/ — Go Rate-Limiting Reverse Proxy

Go HTTP server that acts as a rate-limiting reverse proxy. Sits between NGINX and an upstream service, applying per-user and per-route limits and injecting `X-RateLimit-*` headers on every response — including successful ones.

## Position in the stack

```
NGINX (:80) → Go Proxy (:8080) → UPSTREAM_URL
```

NGINX already handles IP-based limiting. This layer adds identity-aware limits using the JWT in the `Authorization` header.

## Key differentiator

Unlike NGINX (which only sets headers on 429) and the Lambda authorizer (which only intercepts at API GW), this proxy injects `X-RateLimit-Remaining`, `X-RateLimit-Limit`, and `X-RateLimit-Reset` on **every allowed response**, so clients always know how much quota they have left.

## Rate limiting

### Algorithm

Sliding window via Redis sorted sets — same 4-command pipeline used across all three rate limiter types:

```
ZADD  rl:proxy:<user_id>:<route>  <now_ms>  <now_ms>:<rand>
ZREMRANGEBYSCORE  ...  -inf  <window_start_ms>
ZCARD  ...
EXPIRE  ...  61s
```

### Redis key namespace

`rl:proxy:<user_id>:<normalized_route>` — no collision with NGINX (`rl:<ip>`) or Lambda (`rl:user:<id>`).

Route normalization: `/api/v1/users?page=1` → `api:v1:users`

### Limits per user type

| User type | Default (req/min) | `/api/search` | `/api/export` |
|---|---|---|---|
| `basic` | 60 | 20 | 5 |
| `premium` | 600 | 200 | 50 |
| `admin` | unlimited | unlimited | unlimited |

User type is read from the `user_type` or `role` JWT claim. Unknown types default to `basic`.

### No JWT

Requests without a valid `Authorization: Bearer <token>` header are treated as `anonymous` / `basic`.

### Fail-open

If Redis is unavailable, all requests are allowed through with a warning log.

## Headers set on every response

```
X-RateLimit-Limit:     <limit>
X-RateLimit-Remaining: <remaining>
X-RateLimit-Reset:     <unix epoch>
```

On 429:
```
Retry-After: 60
```

## Headers injected to upstream

```
X-User-ID:    <sub claim from JWT>
X-User-Type:  <user_type or role claim>
```

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8080` | HTTP listen port |
| `UPSTREAM_URL` | `` | Backend to proxy to. Empty = echo mode |
| `REDIS_HOST` | `localhost` | Redis host (direct mode) |
| `REDIS_PORT` | `6379` | Redis port |
| `REDIS_MODE` | `direct` | `direct` or `sentinel` |
| `SENTINEL_HOST_1/2/3` | `sentinel-1/2/3` | Sentinel hostnames |
| `SENTINEL_MASTER_NAME` | `mymaster` | Sentinel master name |
| `RATE_LIMIT_BASIC` | `60` | Default req/min for basic users |
| `RATE_LIMIT_PREMIUM` | `600` | Default req/min for premium users |

> When `UPSTREAM_URL` is empty the server runs in **echo mode**: returns request path, method, and headers as JSON. Useful for local testing without a real backend.

## Project structure

```
application/
├── main.go                            # Entry point: wires config → Redis → middleware → proxy
├── go.mod
├── Dockerfile                         # Multi-stage: golang:1.22 → alpine:3.19
└── internal/
    ├── config/config.go               # Env var loading
    ├── jwt/claims.go                  # Bearer token → sub + user_type
    ├── ratelimit/
    │   ├── limiter.go                 # Sliding window (direct or Sentinel)
    │   └── rules.go                   # Per-route limit overrides
    ├── middleware/ratelimit.go        # HTTP middleware: check → headers → 429 or next
    └── proxy/reverse.go              # httputil.ReverseProxy + echo fallback
```

## Local development

Run from `nginx-imp/` to get the full stack (Go proxy + NGINX + Redis Sentinel):

```bash
cd nginx-imp
docker compose up --build
```

Or run the proxy standalone (uses echo mode, no Redis needed if Redis is reachable):

```bash
cd application
go run .
```

## Testing

First, generate a test JWT (requires Go):

```powershell
# basic user
go run scripts/make-token.go
# premium user
go run scripts/make-token.go -user premium-1 -type premium
# admin (unlimited)
go run scripts/make-token.go -user admin-1 -type admin
```

Each command prints the token and a ready-to-run `curl.exe` command.

```powershell
# Health check — exempt from rate limiting
curl.exe http://localhost:8080/health

# Single request — response headers show X-RateLimit-Remaining, X-RateLimit-Limit, X-RateLimit-Reset
curl.exe http://localhost:8080/api/search -H "Authorization: Bearer <token>"

# Trigger 429 on /api/search — basic user limit is 20/min on this route
$token = "Bearer <paste-token-here>"
for ($i=1; $i -le 25; $i++) {
    $code = (curl.exe -s -o NUL -w "%{http_code}" http://localhost:8080/api/search -H "Authorization: $token")
    Write-Host "$i`: $code"
}
# Requests 1-20 → 200, requests 21-25 → 429
```
