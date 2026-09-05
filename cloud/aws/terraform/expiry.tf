# Independent of cloud-init, SSM, the operating system, and the test process.
# Repeated stops also catch an accidental restart of an expired laboratory.
resource "aws_scheduler_schedule_group" "expiry" {
  name = "${local.name}-expiry"
}

resource "aws_iam_role" "expiry" {
  name_prefix = "${local.name}-expiry-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = var.expected_account_id
          "aws:SourceArn"     = aws_scheduler_schedule_group.expiry.arn
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "expiry" {
  name = "stop-this-lab-only"
  role = aws_iam_role.expiry.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:StopInstances"]
      Resource = [aws_instance.lab.arn]
    }]
  })
}

resource "aws_scheduler_schedule" "expiry" {
  name                         = "stop-expired-lab"
  group_name                   = aws_scheduler_schedule_group.expiry.name
  description                  = "Force-stop only this expired lab; host flush gets a ten-minute grace period."
  schedule_expression          = "rate(5 minutes)"
  schedule_expression_timezone = "UTC"
  start_date                   = timeadd(var.expires_at, "10m")
  state                        = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.expiry.arn
    input = jsonencode({
      InstanceIds = [aws_instance.lab.id]
      Force       = true
    })
    retry_policy {
      maximum_event_age_in_seconds = 300
      maximum_retry_attempts       = 2
    }
  }

  depends_on = [aws_iam_role_policy.expiry]
}
