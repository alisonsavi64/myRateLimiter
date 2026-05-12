output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer — use this to hit the app"
  value       = aws_lb.main.dns_name
}

output "ecr_url_go_app" {
  description = "ECR repository URL for the Go application image"
  value       = aws_ecr_repository.go_app.repository_url
}

output "ecr_url_nginx" {
  description = "ECR repository URL for the OpenResty/nginx image"
  value       = aws_ecr_repository.go_app_nginx.repository_url
}

output "redis_primary_endpoint" {
  description = "ElastiCache primary endpoint (write traffic)"
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "redis_reader_endpoint" {
  description = "ElastiCache reader endpoint (read replicas)"
  value       = aws_elasticache_replication_group.redis.reader_endpoint_address
}

output "ssm_param_redis_primary" {
  description = "SSM Parameter Store path for Redis primary endpoint"
  value       = aws_ssm_parameter.redis_primary_endpoint.name
}

output "vpc_id" {
  value = aws_vpc.main.id
}
