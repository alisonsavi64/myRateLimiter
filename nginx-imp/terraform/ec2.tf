resource "aws_security_group" "ec2" {
  name        = "${var.app_name}-ec2-sg"
  description = "EC2 — port 80 from ALB only, outbound open"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.app_name}-ec2-sg" }
}

locals {
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    # Docker
    yum update -y
    amazon-linux-extras install docker -y
    systemctl enable --now docker

    # Docker Compose v2 plugin
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -SL "https://github.com/docker/compose/releases/download/v2.27.0/docker-compose-linux-x86_64" \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

    # AWS CLI v2
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install
    rm -rf /tmp/awscliv2.zip /tmp/aws

    # Fetch Redis primary endpoint from SSM and write env file
    AWS_REGION="${var.aws_region}"
    REDIS_HOST=$(aws ssm get-parameter \
      --region "$AWS_REGION" \
      --name "/${var.app_name}/${var.environment}/redis/primary-endpoint" \
      --query 'Parameter.Value' --output text)

    mkdir -p /opt/app
    cat > /opt/app/.env <<ENVFILE
    REDIS_MODE=direct
    REDIS_PRIMARY_HOST=$REDIS_HOST
    RATE_LIMIT=100
    RATE_BURST=20
    ENVFILE

    # ECR login
    ACCOUNT_ID="${var.aws_account_id}"
    aws ecr get-login-password --region "$AWS_REGION" | \
      docker login --username AWS --password-stdin \
      "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

    # Pull latest images and start stack
    cd /opt/app
    docker compose pull
    docker compose up -d
  EOF
}

resource "aws_launch_template" "app" {
  name_prefix   = "${var.app_name}-lt-"
  image_id      = var.ec2_ami
  instance_type = var.ec2_instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2.arn
  }

  vpc_security_group_ids = [aws_security_group.ec2.id]

  user_data = base64encode(local.user_data)

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = var.app_name
      Environment = var.environment
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "app" {
  name                = "${var.app_name}-asg"
  desired_capacity    = var.ec2_instance_count
  min_size            = 1
  max_size            = var.ec2_instance_count * 2
  vpc_zone_identifier = aws_subnet.private[*].id

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 120

  tag {
    key                 = "Name"
    value               = var.app_name
    propagate_at_launch = true
  }
}
