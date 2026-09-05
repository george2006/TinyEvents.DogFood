data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ssm_parameter" "ubuntu_amd64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name = "tinyevents-lab-${random_id.suffix.hex}"

  common_tags = {
    Project        = "TinyEvents"
    Component      = "CloudDogfood"
    ManagedBy      = "Terraform"
    Owner          = var.owner
    Experiment     = var.experiment_name
    LabExpiresAt   = var.expires_at
    CostAllocation = "TinyEventsV1"
  }
}

resource "aws_vpc" "lab" {
  cidr_block           = "10.71.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = local.name }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = local.name }
}

resource "aws_subnet" "lab" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.71.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = { Name = local.name }
}

resource "aws_route_table" "lab" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = { Name = local.name }
}

resource "aws_route_table_association" "lab" {
  subnet_id      = aws_subnet.lab.id
  route_table_id = aws_route_table.lab.id
}

resource "aws_security_group" "lab" {
  name_prefix = "${local.name}-"
  description = "No-ingress security group for the TinyEvents cloud laboratory"
  vpc_id      = aws_vpc.lab.id

  egress {
    description = "Package, container, AWS API, and source downloads"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = local.name }
}

resource "aws_iam_role" "lab" {
  name_prefix = "${local.name}-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

data "aws_servicequotas_service_quota" "standard_ec2" {
  service_code = "ec2"
  quota_code   = "L-1216C47A"
}

resource "aws_servicequotas_service_quota" "standard_ec2" {
  service_code = "ec2"
  quota_code   = "L-1216C47A"
  value        = var.standard_vcpu_quota
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.lab.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "lab" {
  name_prefix = "${local.name}-"
  role        = aws_iam_role.lab.name
}

resource "aws_s3_bucket" "results" {
  bucket_prefix = "tinyevents-cloud-dogfood-"
  force_destroy = var.allow_results_bucket_destroy

  tags = { Name = "${local.name}-results" }
}

resource "aws_s3_bucket_public_access_block" "results" {
  bucket = aws_s3_bucket.results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    id     = "expire-lab-evidence"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }
  }
}

resource "aws_iam_role_policy" "results" {
  name_prefix = "results-"
  role        = aws_iam_role.lab.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:AbortMultipartUpload", "s3:GetObject", "s3:ListBucket", "s3:PutObject"]
      Resource = [aws_s3_bucket.results.arn, "${aws_s3_bucket.results.arn}/*"]
    }]
  })
}

# One account-wide cost budget per lab state. It is an alert, not a hard cap.
resource "aws_budgets_budget" "lab" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.alert_email]
    }
  }
}

resource "aws_instance" "lab" {
  ami                         = data.aws_ssm_parameter.ubuntu_amd64.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.lab.id
  vpc_security_group_ids      = [aws_security_group.lab.id]
  iam_instance_profile        = aws_iam_instance_profile.lab.name
  associate_public_ip_address = true
  monitoring                  = false

  lifecycle {
    precondition {
      condition     = data.aws_servicequotas_service_quota.standard_ec2.value >= 8
      error_message = "AWS must approve at least 8 Standard On-Demand vCPU before creating the lab."
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = var.root_volume_size_gib
    iops        = 3000
    throughput  = 125
  }

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    expires_at      = var.expires_at
    results_bucket  = aws_s3_bucket.results.id
    evidence_script = file("${path.module}/../host/sync-lab-evidence.sh")
    expiry_script   = file("${path.module}/../host/expire-lab.sh")
  })

  user_data_replace_on_change = true

  depends_on = [aws_iam_role_policy_attachment.ssm, aws_iam_role_policy.results, aws_budgets_budget.lab]

  tags = { Name = local.name }
}
