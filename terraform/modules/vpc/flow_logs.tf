resource "aws_cloudwatch_log_group" "vpc_flow_log" {
  name              = "/aws/vpc-flow-log/${local.name}"
  retention_in_days = var.flow_log_retention_days
}

data "aws_iam_policy_document" "flow_log_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_log" {
  name               = "${local.name}-vpc-flow-log"
  assume_role_policy = data.aws_iam_policy_document.flow_log_assume.json
}

data "aws_iam_policy_document" "flow_log_publish" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    # The trailing ":*" is CloudWatch Logs' own required suffix for
    # stream-level actions under a log group - not a broad wildcard, scoped
    # to this one log group's ARN.
    resources = ["${aws_cloudwatch_log_group.vpc_flow_log.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_log_publish" {
  name   = "${local.name}-vpc-flow-log-publish"
  role   = aws_iam_role.flow_log.id
  policy = data.aws_iam_policy_document.flow_log_publish.json
}

resource "aws_flow_log" "this" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.vpc_flow_log.arn
  iam_role_arn         = aws_iam_role.flow_log.arn

  tags = {
    Name = "${local.name}-flow-log"
  }
}
