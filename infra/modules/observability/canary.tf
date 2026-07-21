# Synthetics heartbeat canary - a scheduled Lambda that AWS manages on our
# behalf, exercising the live URL end to end every 5 minutes. It runs on
# the puppeteer runtime but never drives a browser: canary/canary.js is a
# plain `https` heartbeat, so there's no headless-Chrome cold start to pay
# for on a check this simple.

# --- Artifacts bucket ---------------------------------------------------
# Synthetics writes a screenshot/log/HAR bundle here on every run. Private,
# no lifecycle policy - this is a demo project, the account gets torn down
# rather than tidied - and force_destroy so `make destroy` isn't blocked by
# accumulated run history.

resource "random_id" "artifacts_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "canary_artifacts" {
  bucket        = "${var.name_prefix}-canary-artifacts-${random_id.artifacts_suffix.hex}"
  force_destroy = true

  tags = {
    Name = "${var.name_prefix}-canary-artifacts"
  }
}

resource "aws_s3_bucket_public_access_block" "canary_artifacts" {
  bucket = aws_s3_bucket.canary_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Execution role ------------------------------------------------------
# Synthetics canaries run as a Lambda function AWS manages, so the trust
# policy uses the same lambda.amazonaws.com principal as any other
# function. The inline policy is the documented minimal set for a canary
# that writes artifacts, logs, metrics, and X-Ray segments - nothing from
# the AWS-managed CloudWatchSyntheticsFullAccess policy, which is far
# broader than one heartbeat needs.

data "aws_iam_policy_document" "synthetics_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "synthetics" {
  name               = "${var.name_prefix}-canary"
  assume_role_policy = data.aws_iam_policy_document.synthetics_assume.json

  tags = {
    Name = "${var.name_prefix}-canary"
  }
}

data "aws_iam_policy_document" "synthetics" {
  statement {
    sid       = "ArtifactsReadWrite"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.canary_artifacts.arn}/*"]
  }

  statement {
    sid       = "ArtifactsBucketDiscovery"
    actions   = ["s3:GetBucketLocation", "s3:ListAllMyBuckets"]
    resources = ["*"]
  }

  statement {
    sid       = "CanaryLogs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:log-group:/aws/lambda/cwsyn-*"]
  }

  statement {
    sid       = "CanaryMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["CloudWatchSynthetics"]
    }
  }

  statement {
    sid       = "CanaryTracing"
    actions   = ["xray:PutTraceSegments"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "synthetics" {
  name   = "${var.name_prefix}-canary"
  role   = aws_iam_role.synthetics.id
  policy = data.aws_iam_policy_document.synthetics.json
}

# --- Packaging ------------------------------------------------------------
# Node.js canaries on the puppeteer runtime family must ship their script
# under nodejs/node_modules/<file>.js inside the zip - that's how the
# Synthetics Lambda layer resolves the handler module at runtime. Zipping
# canary/ as a plain directory would put the script at the zip root
# instead, so an explicit `source` block remaps it to the required path;
# the file itself stays at the ordinary canary/canary.js on disk.

data "archive_file" "canary" {
  type        = "zip"
  output_path = "${path.module}/canary.zip"

  source {
    content  = file("${path.module}/canary/canary.js")
    filename = "nodejs/node_modules/canary.js"
  }
}

# --- Canary ---------------------------------------------------------------
# name is 16 characters with the default project prefix - AWS caps
# Synthetics canary names at 21, and this leaves headroom without
# resorting to an abbreviation.

resource "aws_synthetics_canary" "heartbeat" {
  name                 = "${var.name_prefix}-heartbeat"
  artifact_s3_location = "s3://${aws_s3_bucket.canary_artifacts.id}/"
  execution_role_arn   = aws_iam_role.synthetics.arn
  runtime_version      = "syn-nodejs-puppeteer-9.1"
  handler              = "canary.handler"

  zip_file = data.archive_file.canary.output_path

  schedule {
    expression = "rate(5 minutes)"
  }

  run_config {
    timeout_in_seconds = 60

    environment_variables = {
      TARGET_HOST = var.cloudfront_domain
    }
  }

  start_canary  = true
  delete_lambda = true

  tags = {
    Name = "${var.name_prefix}-heartbeat"
  }

  depends_on = [aws_iam_role_policy.synthetics]
}
