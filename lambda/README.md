# lambda/ — Node.js Lambda Rate Limiter (API Gateway Authorizer)

TypeScript Lambda deployed as a REQUEST-type authorizer on API Gateway. Validates JWTs and enforces per-user rate limits before any request reaches EC2. Includes `serverless-offline` for local testing without AWS.

## Position in the stack

```
Client → API Gateway → Lambda Authorizer → ALB → EC2
```

The Lambda runs first. If the user is rate limited, EC2 is never touched.

## Key differentiator

Runs at the API Gateway layer — before NGINX, before the Go proxy, before any EC2 cost is incurred. Applies tiered limits based on user identity extracted from the JWT, with a 300s result cache in API Gateway so repeated requests for the same token don't re-invoke the Lambda.

## How 429 works

API Gateway returns `403` by default when an authorizer denies. A **Gateway Response** mapping converts it:

```
ACCESS_DENIED → 429
+ X-RateLimit-Limit:     $context.authorizer.rateLimitLimit
+ X-RateLimit-Remaining: $context.authorizer.rateLimitRemaining
+ X-RateLimit-Reset:     $context.authorizer.rateLimitReset
+ Retry-After:           60
```

> **Local note**: `serverless-offline` returns **403** (not 429) when the authorizer denies — it doesn't simulate Gateway Response mappings. Both indicate "blocked"; the test script accepts either.

## Rate limiting

### Algorithm

Same 4-command sliding window pipeline used across all three rate limiter types:

```
ZADD  rl:user:<user_id>  <now_ms>  <now_ms>
ZREMRANGEBYSCORE  ...  -inf  <window_start_ms>
ZCARD  ...
EXPIRE  ...  61s
```

### Redis key namespace

`rl:user:<user_id>` — no collision with NGINX (`rl:<ip>`) or Go proxy (`rl:proxy:<id>:<route>`).

### Limits per user type

| User type | Requests/min |
|---|---|
| `basic` | 60 |
| `premium` | 600 |
| `admin` | unlimited (Redis skipped) |
| unknown | 60 (defaults to basic) |

User type is read from `user_type` or `role` JWT claim.

### Fail-open

Redis unavailable → allow request through.

## Environment variables

| Variable | Description |
|---|---|
| `REDIS_HOST` | Redis hostname (default: `redis-master`) |
| `REDIS_PORT` | Default `6379` |
| `RATE_LIMIT_BASIC` | Default `60` |
| `RATE_LIMIT_PREMIUM` | Default `600` |

## Project structure

```
lambda/
├── src/
│   ├── handler.ts      # Lambda authorizer — JWT → Redis → Allow/Deny
│   ├── echo.ts         # Echo backend for local testing
│   ├── ratelimit.ts    # Sliding window via ioredis pipeline
│   ├── jwt.ts          # Bearer → sub + user_type (no re-verification)
│   └── config.ts       # Env var loading
├── serverless.yml      # Serverless Framework + serverless-offline
├── Dockerfile.offline  # Docker image for local serverless-offline
├── package.json
├── tsconfig.json
└── terraform/
    ├── lambda.tf       # Lambda + IAM + Security Groups (update runtime to nodejs22.x)
    └── api_gateway.tf  # REST API GW + REQUEST authorizer + Gateway Response (429)
```

## Local development (serverless-offline)

The full stack including the Lambda is started from the repo root:

```bash
cd nginx-imp
docker compose up --build
```

The `lambda-offline` container runs `serverless offline` on port 3000. Test it:

```bash
node scripts/test-all.js   # includes Section 6: Lambda tests
```

Or manually:

```powershell
# Generate a token
docker run --rm -v ${PWD}:/app -w /app golang:1.22-alpine `
  go run scripts/make-token.go -user user-123 -type basic

# Hit the Lambda endpoint
curl.exe -H "Authorization: Bearer <token>" http://localhost:3000/api/test
```

## Production deploy (Terraform)

> Update `terraform/lambda.tf` runtime from `provided.al2023` (Go) to `nodejs22.x` before applying.

```bash
# Build for production
npm run build        # tsup → dist/handler.js + dist/echo.js

# Zip for Lambda
zip -r lambda.zip dist/ node_modules/

# Deploy infrastructure
cd terraform
terraform init
terraform apply \
  -var="redis_host=<elasticache-endpoint>" \
  -var="private_subnet_ids=[\"subnet-xxx\",\"subnet-yyy\"]" \
  -var="vpc_id=vpc-xxx" \
  -var="elasticache_security_group_id=sg-xxx"
```

## API Gateway authorizer cache

The authorizer result is cached for **300 seconds** keyed on `Authorization` header. One Redis check per token per 5 minutes at steady state.
