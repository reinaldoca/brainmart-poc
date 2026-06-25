variable "repositories" {
  description = "Map of ECR repositories to create. Key = logical name, value = config."
  type = map(object({
    name = string
  }))
}

variable "kms_key_arn" {
  description = "KMS key ARN for ECR encryption. Empty string = use AWS-managed key."
  type        = string
  default     = ""
}

variable "cicd_role_arns" {
  description = "List of IAM role ARNs allowed to push images (CI/CD roles)."
  type        = list(string)
}

variable "ecs_task_execution_role_arns" {
  description = "List of IAM role ARNs allowed to pull images (ECS Task Execution roles)."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags to apply to all ECR resources."
  type        = map(string)
  default     = {}
}
