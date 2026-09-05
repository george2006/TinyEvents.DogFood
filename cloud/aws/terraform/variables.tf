variable "aws_region" {
  description = "AWS region for the disposable laboratory."
  type        = string
  default     = "eu-west-1"
}

variable "aws_profile" {
  description = "Local AWS shared-config profile, or empty to use environment credentials."
  type        = string
  default     = "default"
}

variable "expected_account_id" {
  description = "Explicit account guard for the provider."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "expected_account_id must contain 12 digits."
  }
}

variable "alert_email" {
  description = "Recipient of account-wide monthly budget alerts."
  type        = string
  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be an email address."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly alert threshold in USD, not a spending cap."
  type        = number
  default     = 50
  validation {
    condition     = var.monthly_budget_usd >= 1 && var.monthly_budget_usd <= 2000
    error_message = "monthly_budget_usd must be between 1 and 2000."
  }
}

variable "standard_vcpu_quota" {
  description = "Requested Standard On-Demand quota; preserve a larger existing quota. AWS approval is asynchronous."
  type        = number
  default     = 8
  validation {
    condition     = var.standard_vcpu_quota >= 8
    error_message = "standard_vcpu_quota must be at least 8."
  }
}

variable "owner" {
  description = "Owner tag used for accountability and cost allocation."
  type        = string

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be empty."
  }
}

variable "experiment_name" {
  description = "Short experiment identifier used in names and tags."
  type        = string
  default     = "foundation"
}

variable "instance_type" {
  description = "EC2 type. The accepted starting point is 8 vCPU and 32 GiB."
  type        = string
  default     = "m7i.2xlarge"
}

variable "root_volume_size_gib" {
  description = "Encrypted gp3 root/evidence volume size."
  type        = number
  default     = 150

  validation {
    condition     = var.root_volume_size_gib >= 80 && var.root_volume_size_gib <= 1000
    error_message = "root_volume_size_gib must be between 80 and 1000."
  }
}

variable "expires_at" {
  description = "Mandatory absolute UTC expiry timestamp in RFC3339 form."
  type        = string

  validation {
    condition     = can(timecmp(var.expires_at, var.expires_at))
    error_message = "expires_at must be an RFC3339 timestamp. Deploy-Lab enforces a future expiry; teardown must also work after expiry."
  }
}

variable "allow_results_bucket_destroy" {
  description = "Allow destruction of a non-empty evidence bucket."
  type        = bool
  default     = false
}
