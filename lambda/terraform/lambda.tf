variable "app_name" {
  default = "my-rate-limiter"
}

variable "env" {
  default = "prod"
}

variable "region" {
  default = "us-east-1"
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "vpc_id" {
  type = string
}

variable "elasticache_security_group_id" {
  type = string
}

variable "redis_host" {
  type        = string
  description = "ElastiCache primary endpoint"
}

variable "rate_limit_basic" {
  default = 60
}

variable "rate_limit_premium" {
  default = 600
}

resource "aws_iam_role" "lambda_rate_limiter" {
  name = "${var.app_name}-${var.env}-lambda-rate-limiter"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.lambda_rate_limiter.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "ssm_read" {
  name = "ssm-read"
  role = aws_iam_role.lambda_rate_limiter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters"]
      Resource = "arn:aws:ssm:${var.region}:*:parameter/${var.app_name}/${var.env}/*"
    }]
  })
}

resource "aws_security_group" "lambda_rate_limiter" {
  name   = "${var.app_name}-${var.env}-lambda-rate-limiter"
  vpc_id = var.vpc_id

  egress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.elasticache_security_group_id]
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.app_name}-${var.env}-lambda-rate-limiter"
  }
}

resource "aws_security_group_rule" "elasticache_from_lambda" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = var.elasticache_security_group_id
  source_security_group_id = aws_security_group.lambda_rate_limiter.id
  description              = "Allow Lambda rate limiter to reach ElastiCache"
}

resource "aws_lambda_function" "rate_limiter" {
  function_name = "${var.app_name}-${var.env}-rate-limiter"
  role          = aws_iam_role.lambda_rate_limiter.arn
  runtime       = "provided.al2023"
  architectures = ["arm64"]
  handler       = "bootstrap"
  filename      = "${path.module}/../lambda.zip"
  timeout       = 5
  memory_size   = 128

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda_rate_limiter.id]
  }

  environment {
    variables = {
      REDIS_HOST         = var.redis_host
      REDIS_PORT         = "6379"
      RATE_LIMIT_BASIC   = tostring(var.rate_limit_basic)
      RATE_LIMIT_PREMIUM = tostring(var.rate_limit_premium)
    }
  }

  tags = {
    Name        = "${var.app_name}-${var.env}-rate-limiter"
    Environment = var.env
  }
}

output "lambda_arn" {
  value = aws_lambda_function.rate_limiter.arn
}

output "lambda_invoke_arn" {
  value = aws_lambda_function.rate_limiter.invoke_arn
}
