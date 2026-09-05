# Requires Terraform 1.7+ for provider mocks. No credentials or network required.
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-west-1a"] }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_servicequotas_service_quota" {
    defaults = { value = 16 }
  }
}

mock_provider "random" {}

variables {
  expected_account_id = "123456789012"
  owner               = "offline-test"
  alert_email         = "lab@example.invalid"
  aws_profile         = ""
  expires_at          = "2099-01-01T00:00:00Z"
  standard_vcpu_quota = 16
}

run "foundation_plan" {
  # Apply against provider mocks only to resolve computed role/profile names.
  command = apply
  assert {
    condition     = aws_instance.lab.instance_type == "m7i.2xlarge"
    error_message = "The default lab must remain one 8-vCPU instance type."
  }
  assert {
    condition     = aws_s3_bucket.results.force_destroy == false
    error_message = "Evidence deletion must remain opt-in."
  }
  assert {
    condition     = aws_budgets_budget.lab.limit_amount == "50" && length(aws_budgets_budget.lab.notification) == 3
    error_message = "Terraform must own the 50 USD budget and three alerts."
  }
  assert {
    condition     = alltrue([for n in aws_budgets_budget.lab.notification : contains([50, 80, 100], n.threshold) && contains(n.subscriber_email_addresses, "lab@example.invalid")])
    error_message = "Budget thresholds/recipient differ from the setup contract."
  }
  assert {
    condition     = aws_servicequotas_service_quota.standard_ec2.value == 16
    error_message = "Do not reduce a larger approved quota."
  }
  assert {
    condition     = aws_instance.lab.iam_instance_profile == aws_iam_instance_profile.lab.name
    error_message = "Terraform must own the runtime profile used by EC2."
  }
}

run "expired_configuration_remains_valid_for_teardown" {
  command = plan
  variables {
    expires_at = "2020-01-01T00:00:00Z"
  }
  assert {
    condition     = output.expires_at == "2020-01-01T00:00:00Z"
    error_message = "Expired timestamps must remain readable for teardown; Deploy-Lab guards new deployments."
  }
}

run "low_quota_blocks_compute" {
  command = plan
  override_data {
    target = data.aws_servicequotas_service_quota.standard_ec2
    values = { value = 4 }
  }
  expect_failures = [aws_instance.lab]
}

run "invalid_account_is_rejected" {
  command = plan
  variables {
    expected_account_id = "wrong-account"
  }
  expect_failures = [var.expected_account_id]
}
