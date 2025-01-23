locals {
  region        = "us-east-2"
  credentials   = ["~/.aws/credentials"]
  profile       = "default"
  user_policies = ["arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess", "arn:aws:iam::aws:policy/AmazonECS_FullAccess"]

  name           = "vproapp"
  container_port = 8080
  role_policies  = ["arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy", "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"]
  capacity       = ["FARGATE", "FARGATE_SPOT"]
}

provider "aws" {
  region                   = local.region
  shared_credentials_files = local.credentials
  profile                  = local.profile
}

resource "aws_iam_user" "this" {
  name = "jenkins"
}

resource "aws_iam_user_policy_attachment" "this" {
  for_each = toset(local.user_policies)

  user       = aws_iam_user.this.id
  policy_arn = each.key
}

resource "aws_iam_access_key" "this" {
  user = aws_iam_user.this.id
}

resource "aws_ecr_repository" "this" {
  name         = "vprofileappimg"
  force_delete = true
}

resource "aws_ecs_cluster" "this" {
  name = "vprofile"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = local.capacity

  dynamic "default_capacity_provider_strategy" {
    for_each = local.capacity

    content {
      capacity_provider = default_capacity_provider_strategy.value
      base              = 0
      weight            = 1
    }
  }
}

resource "aws_ecs_task_definition" "this" {
  family                   = "vproapptask"
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.this.arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = local.name
      image     = aws_ecr_repository.this.repository_url
      cpu       = 0
      essential = true

      portMappings = [{
        name          = "${local.name}-8080-tcp"
        containerPort = local.container_port
        protocol      = "tcp"
        hostPort      = local.container_port
      }]

      logConfiguration = {
        logDriver     = "awslogs"
        secretOptions = []

        options = {
          awslogs-group         = "/ecs/${local.name}"
          mode                  = "non-blocking"
          awslogs-create-group  = "true"
          max-buffer-size       = "25m"
          awslogs-region        = local.region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  depends_on = [aws_iam_role.this]
}

resource "aws_iam_role" "this" {
  name        = "ecs_task_execution_role"
  description = "ECS role for a logging"

  assume_role_policy = jsonencode({
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"

      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each = toset(local.role_policies)

  role       = aws_iam_role.this.id
  policy_arn = each.key
}

resource "aws_ecs_service" "this" {
  name    = "vproappsvc"
  cluster = aws_ecs_cluster.this.arn
  task_definition = aws_ecs_task_definition.this.arn
  deployment_minimum_healthy_percent = 100
  desired_count                      = 1
  deployment_maximum_percent         = 200

  capacity_provider_strategy {
    base              = 0
    capacity_provider = "FARGATE"
    weight            = 1
  }

  deployment_circuit_breaker {
    enable   = false
    rollback = false
  }

  deployment_controller {
    type = "ECS"
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = jsondecode(aws_ecs_task_definition.this.container_definitions)[0]["name"]
    container_port   = jsondecode(aws_ecs_task_definition.this.container_definitions)[0]["portMappings"][0]["hostPort"]
  }

  network_configuration {
    assign_public_ip = true
    security_groups  = [aws_security_group.container_sg.id, aws_security_group.out_sg.id]
    subnets          = data.aws_subnets.this.ids
  }
}

data "aws_vpc" "this" {
  default = true
}

data "aws_subnets" "this" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
}

resource "aws_lb" "this" {
  name               = "vproapp-ecs-alb"
  subnets            = data.aws_subnets.this.ids
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id, aws_security_group.out_sg.id]
}

resource "aws_lb_target_group" "this" {
  name        = "vproapplb"
  port        = local.container_port
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.this.id
  target_type = "ip"

  health_check {
    path = "/login"
  }
}

resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

resource "aws_security_group" "lb_sg" {
  name = "vproapp-alb-sg"
}

resource "aws_vpc_security_group_ingress_rule" "lb_isg" {
  security_group_id = aws_security_group.lb_sg.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_security_group" "container_sg" {
  name = "vproapp-container-sg"
}

resource "aws_vpc_security_group_ingress_rule" "container_isg" {
  security_group_id            = aws_security_group.container_sg.id
  ip_protocol                  = "tcp"
  from_port                    = local.container_port
  to_port                      = local.container_port
  referenced_security_group_id = aws_security_group.lb_sg.id
}

resource "aws_security_group" "out_sg" {
  name = "vproapp-out-sg"
}

resource "aws_vpc_security_group_egress_rule" "out_esg" {
  security_group_id = aws_security_group.out_sg.id
  ip_protocol       = -1
  cidr_ipv4         = "0.0.0.0/0"
}