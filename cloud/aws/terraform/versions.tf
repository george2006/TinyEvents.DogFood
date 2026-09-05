terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region              = var.aws_region
  profile             = var.aws_profile == "" ? null : var.aws_profile
  allowed_account_ids = [var.expected_account_id]

  default_tags {
    tags = local.common_tags
  }
}
