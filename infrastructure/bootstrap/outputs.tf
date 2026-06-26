output "kms_key_id" {
  description = "KMS key ID — use in root.hcl kms_key_id."
  value       = aws_kms_key.tfstate.key_id
}

output "kms_key_arn" {
  description = "KMS key ARN."
  value       = aws_kms_key.tfstate.arn
}

output "kms_alias" {
  description = "KMS alias name — referenced in root.hcl as kms_key_id."
  value       = aws_kms_alias.tfstate.name
}

output "s3_bucket" {
  description = "S3 bucket name for Terraform state."
  value       = aws_s3_bucket.tfstate.bucket
}

output "dynamodb_table" {
  description = "DynamoDB table name for state locking."
  value       = aws_dynamodb_table.tfstate_lock.name
}
