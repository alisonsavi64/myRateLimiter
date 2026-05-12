variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev / prod)"
  type        = string
  default     = "prod"
}

variable "app_name" {
  description = "Base name used for all AWS resources"
  type        = string
  default     = "go-app"
}

variable "aws_account_id" {
  description = "AWS account ID — used in user_data for ECR login"
  type        = string
}

variable "ec2_instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "ec2_instance_count" {
  description = "Desired number of EC2 instances"
  type        = number
  default     = 2
}

variable "ec2_ami" {
  description = "Amazon Linux 2 AMI ID (region-specific). Find the latest with: aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/amzn2-ami-hvm-x86_64-gp2"
  type        = string
  default     = "ami-0c02fb55956c7d316"  # us-east-1, update per region
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "redis_node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_num_replicas" {
  description = "Number of read replica nodes (total nodes = replicas + 1 primary)"
  type        = number
  default     = 2
}
