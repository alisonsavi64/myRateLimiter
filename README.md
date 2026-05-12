# go-app

Go HTTP API with Nginx rate limiting via Redis Sentinel, GitLab CI/CD, and AWS infrastructure managed by Terraform.

## Architecture

```
Internet
    │
   ALB  (public subnets, port 80/443)
    │   health check: GET /health
    │
EC2 ASG  (private subnets)
 ├── OpenResty/Nginx  :80   ──── rate_limit.lua ──→ ElastiCache Redis
 └── Go app           :8080 (internal only)

ElastiCache Redis  (private subnets)
 └── 1 primary + 2 read replicas, automatic failover
```

**Rate limiting:** 100 req/min per client IP, burst of 20, sliding window via Redis sorted sets. `/health` is exempt (used by ALB health checks).

## Project structure

```
go/
├── application/          Go HTTP server
│   ├── main.go           GET /health → {"status":"ok","timestamp":"..."}
│   ├── go.mod            module go-app, go 1.22
│   └── Dockerfile        multi-stage build (golang:1.22-alpine → alpine:3.19)
│
└── nginx-imp/            Rate limiter + infra
    ├── Dockerfile        OpenResty (nginx + Lua), port 80
    ├── nginx.conf        worker config, lua_shared_dict
    ├── conf.d/
    │   └── default.conf  reverse proxy + rate limit routing
    ├── lua/
    │   └── rate_limit.lua  sliding window, sentinel/direct Redis modes
    ├── redis/
    │   ├── redis-master.conf
    │   ├── redis-replica.conf
    │   └── sentinel.conf   quorum = 2 of 3
    ├── docker-compose.yml  full local stack (8 services)
    ├── .gitlab-ci.yml      test → build → deploy pipeline
    └── terraform/          AWS infrastructure
        ├── main.tf / variables.tf / outputs.tf
        ├── vpc.tf          VPC, subnets, NAT gateway
        ├── alb.tf          Application Load Balancer
        ├── ec2.tf          Auto Scaling Group + Launch Template
        ├── elasticache.tf  Redis replication group + SSM params
        ├── ecr.tf          ECR repositories (go-app, go-app-nginx)
        └── iam.tf          EC2 role with ECR pull + SSM access
```

## Local development

```bash
cd nginx-imp
docker compose up --build
```

Services started:

| Container | Port | Description |
|---|---|---|
| nginx | 80 | OpenResty rate limiter + reverse proxy |
| go-app | 8080 (internal) | Go HTTP server |
| redis-master | 6379 (internal) | Redis primary |
| redis-replica-1/2 | 6379 (internal) | Read replicas |
| sentinel-1/2/3 | 26379 (internal) | Sentinel quorum |

### Test the health endpoint (exempt from rate limit)

```bash
curl http://localhost/health
# {"status":"ok","timestamp":"2026-05-11T21:00:00Z"}
```

### Test rate limiting (PowerShell)

```powershell
for ($i=1; $i -le 125; $i++) {
    try {
        $r = Invoke-WebRequest http://localhost/ -UseBasicParsing
        Write-Host "$i : $($r.StatusCode)"
    } catch {
        Write-Host "$i : $($_.Exception.Response.StatusCode.value__)"
    }
}
# Requests 1-120 → 404 (Go app has no / route, but rate limiter passes them)
# Requests 121-125 → 429 rate limit exceeded
```

### Verify Redis Sentinel topology

```bash
docker exec sentinel-1 redis-cli -p 26379 sentinel masters
docker exec redis-master redis-cli info replication
```

## Environment variables (nginx-imp)

| Variable | Default | Description |
|---|---|---|
| `REDIS_MODE` | `sentinel` | `sentinel` (local) or `direct` (AWS ElastiCache) |
| `SENTINEL_HOST_1/2/3` | `sentinel-1/2/3` | Sentinel hostnames |
| `SENTINEL_MASTER_NAME` | `mymaster` | Sentinel master name |
| `REDIS_PRIMARY_HOST` | `localhost` | Used when `REDIS_MODE=direct` |
| `RATE_LIMIT` | `100` | Max requests per minute per IP |
| `RATE_BURST` | `20` | Burst allowance on top of limit |

## CI/CD (GitLab)

Pipeline stages: **test** → **build** → **deploy**

| Stage | What it does |
|---|---|
| test | `go vet` + `go test -race` on every MR and push to main |
| build | Builds `go-app` and `go-app-nginx` images, pushes to ECR with `$CI_COMMIT_SHA` and `latest` tags |
| deploy | Runs `docker compose up -d` on EC2 via AWS SSM Run Command (no SSH needed) |

### Required GitLab CI variables

Set in **Settings → CI/CD → Variables**:

| Variable | Mask | Description |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | yes | IAM key: ECR push + SSM + EC2 describe |
| `AWS_SECRET_ACCESS_KEY` | yes | IAM secret |
| `AWS_REGION` | no | e.g. `us-east-1` |
| `AWS_ACCOUNT_ID` | no | 12-digit AWS account number |
| `EC2_INSTANCE_TAG` | no | Value of the `Name` tag on EC2 instances |

## AWS infrastructure (Terraform)

```bash
cd nginx-imp/terraform
terraform init
terraform apply -var="aws_account_id=<your-account-id>"
```

Key outputs after apply:

| Output | Description |
|---|---|
| `alb_dns_name` | Public DNS — point your domain here |
| `ecr_url_go_app` | ECR URL for the Go app image |
| `ecr_url_nginx` | ECR URL for the nginx image |
| `redis_primary_endpoint` | ElastiCache write endpoint |
| `ssm_param_redis_primary` | SSM path read by EC2 at boot |

### Terraform variables (key overrides)

| Variable | Default | Override for |
|---|---|---|
| `aws_region` | `us-east-1` | Different region |
| `ec2_instance_type` | `t3.medium` | Cost/performance tuning |
| `ec2_instance_count` | `2` | Scale out |
| `redis_node_type` | `cache.t3.micro` | Higher throughput |
| `ec2_ami` | `ami-0c02fb55956c7d316` | Must match region |
