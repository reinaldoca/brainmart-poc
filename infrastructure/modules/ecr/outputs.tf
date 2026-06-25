output "repository_urls" {
  description = "Map of repository name -> URL (used as ECR_REGISTRY in CI/CD)."
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "repository_arns" {
  description = "Map of repository name -> ARN (used in IAM policies)."
  value       = { for k, v in aws_ecr_repository.this : k => v.arn }
}

output "registry_id" {
  description = "AWS account ID that owns the registry (= ECR registry ID)."
  value       = one(values(aws_ecr_repository.this)).registry_id
}
