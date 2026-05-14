# Rate Limiter — System Design Study

Study project implementing three different rate limiting strategies to compare their trade-offs in terms of performance, flexibility, and operational complexity.

## The Three Types

| # | Subproject | Strategy | Key capability |
|---|---|---|---|
| 1 | [nginx-imp/](nginx-imp/) | NGINX + Lua + Redis | IP-based, infra-level, no app code |
| 2 | [application/](application/) | Go reverse proxy | Per-user + per-route, injects headers on every response |
| 3 | [lambda/](lambda/) | Go Lambda (API Gateway) | JWT-based user tiers, runs before EC2 |

## Full Architecture

```
Client
  │
  ▼
API Gateway  ──── Lambda Authorizer (lambda/)
  │                  • validates JWT
  │                  • per-user rate limit (Redis)
  │                  • basic/premium/admin tiers
  │                  • returns 429 via Gateway Response
  ▼
ALB (port 80/443)
  │
  ▼
EC2 Auto Scaling Group
  ├── NGINX / OpenResty (nginx-imp/)   :80
  │     • IP-based rate limit (100 req/min)
  │     • sliding window via Redis sorted sets
  │     • Redis Sentinel (local) / ElastiCache (AWS)
  │
  └── Go Proxy (application/)          :8080
        • per-user + per-route rate limit
        • X-RateLimit-* headers on every response
        • proxies to UPSTREAM_URL
        • Redis Sentinel (local) / ElastiCache (AWS)

Redis
  • local: 1 master + 2 replicas + 3 sentinels (docker-compose)
  • AWS:   ElastiCache with Multi-AZ auto-failover
```

## Redis Key Namespaces (no collisions)

| Layer | Key format |
|---|---|
| NGINX | `rl:<client_ip>` |
| Go proxy | `rl:proxy:<user_id>:<route>` |
| Lambda | `rl:user:<user_id>` |

## Quick Start (local)

```bash
cd nginx-imp
docker compose up --build
```

Generate a test JWT (requires Go):
```powershell
go run scripts/make-token.go
# prints: Bearer eyJ...  +  a ready-to-run curl.exe command
```

```powershell
curl.exe http://localhost/health
curl.exe http://localhost/api/search -H "Authorization: Bearer <token-from-above>"
```

## Subproject READMEs

- [nginx-imp/README.md](nginx-imp/README.md) — NGINX + Lua + Redis Sentinel, Terraform, GitLab CI/CD
- [application/README.md](application/README.md) — Go reverse proxy, per-user/route limits
- [lambda/README.md](lambda/README.md) — Go Lambda authorizer, API Gateway, Terraform
