# Ingestion module - scheduled Lambda that pulls USGS earthquake data into
# the database. Handler logic lands in a later commit; this module ships
# the infrastructure plus a neutral stub so packaging and the plan work
# end to end.
#
# Same cross-module pattern as the api module: the database hands this
# module a rule-free security group (db_sg_id), and the ingress rule that
# lets the ingestion Lambda reach it on 5432 is attached here, directly on
# the database's SG, avoiding a dependency cycle between the two modules.

# --- Packaging ------------------------------------------------------------
# source_dir is populated by `make package-ingestion` (vendors psycopg[binary]
# for manylinux2014_x86_64 / Python 3.12, then copies handler.py in) before
# this is ever planned - see the Makefile.

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.root}/../ingestion/build"
  output_path = "${path.root}/../ingestion/build.zip"
}

# --- Logging ----------------------------------------------------------------
# Created explicitly, ahead of the function, so the log group's retention
# policy is in place before the function could ever write to it.

resource "aws_cloudwatch_log_group" "ingestion" {
  name              = "/aws/lambda/${var.name_prefix}-ingestion"
  retention_in_days = 14

  tags = {
    Name = "${var.name_prefix}-ingestion"
  }
}

# --- Security group -----------------------------------------------------
# No inline rules - every rule is its own resource. Egress only: nothing
# initiates connections into this Lambda over the network.

resource "aws_security_group" "ingestion" {
  name   = "${var.name_prefix}-ingestion"
  vpc_id = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-ingestion"
  }
}

resource "aws_vpc_security_group_egress_rule" "ingestion_to_internet_https" {
  security_group_id = aws_security_group.ingestion.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS egress to the USGS API and AWS APIs via the NAT gateway."
}

resource "aws_vpc_security_group_egress_rule" "ingestion_to_db" {
  security_group_id            = aws_security_group.ingestion.id
  referenced_security_group_id = var.db_sg_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL egress to the database."
}

resource "aws_vpc_security_group_ingress_rule" "db_from_ingestion" {
  security_group_id            = var.db_sg_id
  referenced_security_group_id = aws_security_group.ingestion.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL ingress from the ingestion Lambda."
}

# --- IAM ------------------------------------------------------------------
# Managed AWSLambdaVPCAccessExecutionRole covers both basic execution
# (log group access) and the ENI permissions VPC-attached Lambdas need.
# The two inline policies are scoped to exactly what the handler needs:
# the one DB secret, and PutMetricData restricted to this project's
# CloudWatch namespace.

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ingestion" {
  name               = "${var.name_prefix}-ingestion"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = {
    Name = "${var.name_prefix}-ingestion"
  }
}

resource "aws_iam_role_policy_attachment" "ingestion_vpc_access" {
  role       = aws_iam_role.ingestion.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "ingestion_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn]
  }
}

resource "aws_iam_role_policy" "ingestion_secrets" {
  name   = "${var.name_prefix}-ingestion-db-secret"
  role   = aws_iam_role.ingestion.id
  policy = data.aws_iam_policy_document.ingestion_secrets.json
}

data "aws_iam_policy_document" "ingestion_metrics" {
  statement {
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["TCGL01"]
    }
  }
}

resource "aws_iam_role_policy" "ingestion_metrics" {
  name   = "${var.name_prefix}-ingestion-metrics"
  role   = aws_iam_role.ingestion.id
  policy = data.aws_iam_policy_document.ingestion_metrics.json
}

# --- Lambda -----------------------------------------------------------

resource "aws_lambda_function" "ingestion" {
  function_name = "${var.name_prefix}-ingestion"
  role          = aws_iam_role.ingestion.arn

  runtime       = "python3.12"
  handler       = "handler.lambda_handler"
  architectures = ["x86_64"]
  timeout       = 120
  memory_size   = 512

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.ingestion.id]
  }

  environment {
    variables = {
      DB_SECRET_ARN    = var.db_secret_arn
      DB_HOST          = var.db_host
      DB_PORT          = tostring(var.db_port)
      DB_NAME          = var.db_name
      USGS_BASE        = "https://earthquake.usgs.gov/fdsnws/event/1/query"
      BACKFILL_DAYS    = "30"
      METRIC_NAMESPACE = "TCGL01"
    }
  }

  depends_on = [aws_cloudwatch_log_group.ingestion]

  tags = {
    Name = "${var.name_prefix}-ingestion"
  }
}

# --- Schedule (EventBridge) ---------------------------------------------

resource "aws_cloudwatch_event_rule" "ingestion_schedule" {
  name                = "${var.name_prefix}-ingestion-schedule"
  schedule_expression = "rate(5 minutes)"

  tags = {
    Name = "${var.name_prefix}-ingestion-schedule"
  }
}

resource "aws_cloudwatch_event_target" "ingestion" {
  rule = aws_cloudwatch_event_rule.ingestion_schedule.name
  arn  = aws_lambda_function.ingestion.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingestion.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ingestion_schedule.arn
}
