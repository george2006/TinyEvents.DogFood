output "instance_id" {
  description = "EC2 instance used by the laboratory."
  value       = aws_instance.lab.id
}

output "instance_name" {
  description = "Name tag of the laboratory instance."
  value       = local.name
}

output "results_bucket" {
  description = "Private S3 bucket for experiment evidence."
  value       = aws_s3_bucket.results.id
}

output "expires_at" {
  description = "Mandatory laboratory expiry."
  value       = var.expires_at
}

output "ami_id" {
  description = "Resolved Ubuntu 24.04 AMI."
  # This fixed Canonical public parameter contains an AMI ID, not a secret.
  value = nonsensitive(data.aws_ssm_parameter.ubuntu_amd64.value)
}

output "aws_region" {
  value = var.aws_region
}

output "account_id" {
  value = var.expected_account_id
}

output "alert_email" {
  value = var.alert_email
}

output "monthly_budget_usd" {
  value = var.monthly_budget_usd
}

output "standard_vcpu_quota" {
  value = var.standard_vcpu_quota
}
