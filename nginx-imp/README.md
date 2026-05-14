# nginx-imp/ — NGINX + Lua + Redis Rate Limiter

OpenResty (NGINX + Lua) rate limiter with Redis Sentinel for high availability. The first layer of defense — enforces IP-based limits at the infrastructure level before any application code runs.

## Position in the stack

```
ALB → NGINX (:80) → Go Proxy (:8080)
```

## Key differentiator

Zero application code involved. The rate limiter is pure infrastructure: a Lua script evaluated by NGINX on every request, backed by a Redis cluster. Works regardless of what application runs behind it.

## Rate limiting algorithm

Sliding window via Redis sorted sets. For each request:

```lua
ZADD  rl:<client_ip>  <now_ms>  <now_ms>:<rand>
ZREMRANGEBYSCORE  rl:<client_ip>  -inf  <window_start_ms>
ZCARD  rl:<client_ip>
EXPIRE  rl:<client_ip>  61
```

- Window: 60 seconds
- Default limit: 100 req/min per IP + 20 burst (120 effective)
- `/health` is exempt (used by ALB health checks)
- Fail-open: Redis unavailable → request passes through

## Redis modes

| Mode | When | Config |
|---|---|---|
| `sentinel` | Local / Docker | 3-sentinel quorum, master discovery cached 30s |
| `direct` | AWS / ElastiCache | Single endpoint, no Sentinel protocol |

Set via `REDIS_MODE` env var.

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `REDIS_MODE` | `sentinel` | `sentinel` or `direct` |
| `SENTINEL_HOST_1/2/3` | `sentinel-1/2/3` | Sentinel hostnames |
| `SENTINEL_MASTER_NAME` | `mymaster` | Sentinel master name |
| `REDIS_PRIMARY_HOST` | `localhost` | Used when `REDIS_MODE=direct` |
| `RATE_LIMIT` | `100` | Max requests per minute per IP |
| `RATE_BURST` | `20` | Burst on top of limit |

## Project structure

```
nginx-imp/
├── Dockerfile              OpenResty image
├── nginx.conf              Worker config, lua_shared_dict (Sentinel master cache)
├── conf.d/
│   └── default.conf        Upstream + rate limit routing
├── lua/
│   └── rate_limit.lua      Sliding window algorithm + Sentinel discovery
├── redis/
│   ├── redis-master.conf   RDB + AOF persistence, allkeys-lru
│   ├── redis-replica.conf  Read-only replicas
│   └── sentinel.conf       Quorum = 2 of 3
├── docker-compose.yml      Full local stack (8 services)
├── .gitlab-ci.yml          test → build → deploy pipeline
└── terraform/              AWS infrastructure
    ├── vpc.tf              VPC, subnets, NAT gateway
    ├── alb.tf              Application Load Balancer
    ├── ec2.tf              Auto Scaling Group + user data (Docker + SSM bootstrap)
    ├── elasticache.tf      Redis replication group, Multi-AZ, SSM params
    ├── ecr.tf              ECR repos (go-app, go-app-nginx)
    └── iam.tf              EC2 role: ECR pull + SSM read
```

## Local development

```bash
docker compose up --build
```

| Container | Port | Description |
|---|---|---|
| nginx | 80 | OpenResty rate limiter |
| go-app | 8080 (internal) | Go reverse proxy |
| redis-master | 6379 (internal) | Redis primary |
| redis-replica-1/2 | 6379 (internal) | Read replicas |
| sentinel-1/2/3 | 26379 (internal) | Sentinel quorum |

## Testing

```powershell
# Health — exempt from rate limiting
curl.exe http://localhost/health

# Trigger 429 — default limit is 120 requests (100 + 20 burst)
for ($i=1; $i -le 125; $i++) {
    $code = (curl.exe -s -o NUL -w "%{http_code}" http://localhost/)
    Write-Host "$i`: $code"
}
# Requests 1-120 → 200 (echo mode) or 404 (no / route), 121+ → 429

# Verify Redis Sentinel is healthy
docker exec sentinel-1 redis-cli -p 26379 sentinel masters
docker exec redis-master redis-cli info replication
```

## CI/CD (GitLab)

**Pipeline stages:** test → build → deploy

| Stage | Trigger | What it does |
|---|---|---|
| test | MR + push to main | `go vet` + `go test -race` |
| build | Push to main | Builds `go-app` + `go-app-nginx` images, pushes to ECR with `$CI_COMMIT_SHA` + `latest` |
| deploy | Push to main | Runs `docker compose up -d` on EC2 via SSM Run Command (no SSH) |

**Required GitLab CI variables:**

| Variable | Masked | Description |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | yes | IAM key |
| `AWS_SECRET_ACCESS_KEY` | yes | IAM secret |
| `AWS_REGION` | no | e.g. `us-east-1` |
| `AWS_ACCOUNT_ID` | no | 12-digit account number |
| `EC2_INSTANCE_TAG` | no | Value of the `Name` tag on EC2 instances |

## AWS infrastructure (Terraform)

```bash
cd terraform
terraform init
terraform apply -var="aws_account_id=<your-account-id>"
```

**Key outputs:**

| Output | Description |
|---|---|
| `alb_dns_name` | Public DNS — point your domain here |
| `ecr_url_go_app` | ECR URL for the Go app image |
| `ecr_url_nginx` | ECR URL for the NGINX image |
| `redis_primary_endpoint` | ElastiCache write endpoint |
| `ssm_param_redis_primary` | SSM path read by EC2 at boot |

**Key Terraform variables:**

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-east-1` | AWS region |
| `ec2_instance_type` | `t3.medium` | EC2 size |
| `ec2_instance_count` | `2` | ASG desired count |
| `redis_node_type` | `cache.t3.micro` | ElastiCache node size |
