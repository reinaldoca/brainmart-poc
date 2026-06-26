variable "account_id" {
  description = "AWS account ID where the bootstrap resources are created."
  type        = string
}

variable "region" {
  description = "AWS region (e.g. us-east-1)."
  type        = string
  default     = "us-east-1"
}

variable "cicd_role_arn" {
  description = "ARN of the CI/CD IAM role that needs access to the KMS key and S3 bucket."
  type        = string
}
