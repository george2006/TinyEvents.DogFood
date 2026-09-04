variable "aws_region" {
  description = "AWS region for the disposable laboratory."
  type        = string
  default     = "eu-west-1"
}

variable "aws_profile" {
  description = "Local AWS shared-config profile used by Terraform."
  type        = string
  default     = "default"
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
    condition     = can(timecmp(var.expires_at, timestamp())) && timecmp(var.expires_at, timestamp()) > 0
    error_message = "expires_at must be a future RFC3339 timestamp."
  }
}

variable "allow_results_bucket_destroy" {
  description = "Allow destruction of a non-empty evidence bucket."
  type        = bool
  default     = false
}
