resource "aws_security_group" "redis" {
  name        = "${var.app_name}-redis-sg"
  description = "ElastiCache Redis — allow 6379 from EC2 SG only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Redis from EC2"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.app_name}-redis-sg" }
}

resource "aws_elasticache_subnet_group" "redis" {
  name       = "${var.app_name}-redis-subnet-group"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_elasticache_parameter_group" "redis" {
  name        = "${var.app_name}-redis-params"
  family      = "redis7"
  description = "Rate limiter Redis params"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }
}

# ElastiCache replication group with automatic failover.
# NOTE: ElastiCache does NOT expose the Redis Sentinel protocol (port 26379).
# Failover is handled internally; the primary_endpoint_address DNS updates automatically.
# The nginx Lua code connects directly to the primary endpoint (REDIS_MODE=direct).
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${var.app_name}-redis"
  description          = "Redis for distributed rate limiting"

  node_type            = var.redis_node_type
  port                 = 6379
  parameter_group_name = aws_elasticache_parameter_group.redis.name
  subnet_group_name    = aws_elasticache_subnet_group.redis.name
  security_group_ids   = [aws_security_group.redis.id]

  num_cache_clusters         = var.redis_num_replicas + 1
  automatic_failover_enabled = true
  multi_az_enabled           = true

  engine_version              = "7.1"
  at_rest_encryption_enabled  = true
  transit_encryption_enabled  = false

  apply_immediately = false

  tags = { Name = "${var.app_name}-redis" }
}

# Store endpoints in SSM so EC2 user_data and CI can read them without hardcoding
resource "aws_ssm_parameter" "redis_primary_endpoint" {
  name  = "/${var.app_name}/${var.environment}/redis/primary-endpoint"
  type  = "String"
  value = aws_elasticache_replication_group.redis.primary_endpoint_address
  tags  = { Name = "${var.app_name}-redis-primary" }
}

resource "aws_ssm_parameter" "redis_reader_endpoint" {
  name  = "/${var.app_name}/${var.environment}/redis/reader-endpoint"
  type  = "String"
  value = aws_elasticache_replication_group.redis.reader_endpoint_address
  tags  = { Name = "${var.app_name}-redis-reader" }
}
