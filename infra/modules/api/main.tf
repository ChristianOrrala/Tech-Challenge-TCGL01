# API module - ECR repo, ECS Fargate service, and the api-side security
# groups. The ALB and its own security group live in alb.tf; both files
# are one module namespace, so cross-references between them are fine.
#
# The database module hands this module a rule-free security group
# (db_sg_id) by design - the ingress rule that lets this service reach
# it on 5432 is attached here, directly on the database's SG, which
# avoids a dependency cycle between the two modules.

data "aws_region" "current" {}

resource "aws_ecr_repository" "api" {
  name         = "${var.name_prefix}-api"
  force_delete = true # demo teardown - no orphaned repo blocking `make destroy`

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.name_prefix}-api"
  }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.name_prefix}-api"
  retention_in_days = 14

  tags = {
    Name = "${var.name_prefix}-api"
  }
}

resource "aws_ecs_cluster" "this" {
  name = var.name_prefix

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = var.name_prefix
  }
}

# --- Security groups ---------------------------------------------------
# Two SGs, no inline rules on either - every rule is its own resource so
# the api <-> alb <-> db relationships stay legible and cycle-free.

resource "aws_security_group" "api" {
  name   = "${var.name_prefix}-api"
  vpc_id = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-api"
  }
}

resource "aws_vpc_security_group_ingress_rule" "api_from_alb" {
  security_group_id            = aws_security_group.api.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8000
  to_port                      = 8000
  ip_protocol                  = "tcp"
  description                  = "API traffic from the ALB."
}

resource "aws_vpc_security_group_egress_rule" "api_to_internet_https" {
  security_group_id = aws_security_group.api.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS egress for ECR, CloudWatch Logs, and Secrets Manager via the NAT gateway."
}

resource "aws_vpc_security_group_egress_rule" "api_to_db" {
  security_group_id            = aws_security_group.api.id
  referenced_security_group_id = var.db_sg_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL egress to the database."
}

resource "aws_vpc_security_group_ingress_rule" "db_from_api" {
  security_group_id            = var.db_sg_id
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL ingress from the API service."
}

# --- ECS task + service --------------------------------------------------

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.name_prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = "${aws_ecr_repository.api.repository_url}:${var.image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = 8000
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "DB_HOST", value = var.db_host },
        { name = "DB_PORT", value = tostring(var.db_port) },
        { name = "DB_NAME", value = var.db_name },
      ]

      secrets = [
        { name = "DB_CREDS", valueFrom = var.db_secret_arn },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "api"
        }
      }
    }
  ])

  tags = {
    Name = "${var.name_prefix}-api"
  }
}

resource "aws_ecs_service" "api" {
  name            = "${var.name_prefix}-api"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api.arn
  launch_type     = "FARGATE"
  desired_count   = var.desired_count

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8000
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 60

  # Wait for the listener so the target group can actually route before
  # the service starts pushing tasks through its health checks.
  depends_on = [aws_lb_listener.http]

  tags = {
    Name = "${var.name_prefix}-api"
  }
}
