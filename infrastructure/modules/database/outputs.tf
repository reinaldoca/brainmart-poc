output "db_instance_id" {
  description = "ID de la instancia RDS"
  value       = aws_db_instance.main.id
}

output "db_instance_arn" {
  description = "ARN de la instancia RDS"
  value       = aws_db_instance.main.arn
}

output "db_instance_endpoint" {
  description = "Endpoint de conexio?n a la BD (host:port)"
  value       = aws_db_instance.main.endpoint
}

output "db_instance_address" {
  description = "Host del endpoint (sin el port)"
  value       = aws_db_instance.main.address
}

output "db_instance_port" {
  description = "Puerto de la BD (5432 para PostgreSQL)"
  value       = aws_db_instance.main.port
}

output "db_name" {
  description = "Nombre de la base de datos"
  value       = aws_db_instance.main.db_name
}

output "kms_key_arn" {
  description = "ARN de la KMS CMK usada para cifrar la BD"
  value       = local.kms_key_arn
}

output "kms_key_id" {
  description = "ID de la KMS CMK"
  value       = length(aws_kms_key.rds) > 0 ? aws_kms_key.rds[0].key_id : var.kms_key_id
}

output "secret_arn" {
  description = "ARN del secreto en Secrets Manager con las credenciales de la BD"
  value       = aws_secretsmanager_secret.db_password.arn
  sensitive   = true  # No mostrar en plan output
}

output "secret_name" {
  description = "Nombre del secreto en Secrets Manager"
  value       = aws_secretsmanager_secret.db_password.name
}

output "audit_export_lambda_arn" {
  description = "ARN de la Lambda que exporta audit_log a S3"
  value       = var.enable_audit_export ? aws_lambda_function.audit_export[0].arn : null
}

output "rds_alerts_topic_arn" {
  description = "ARN del topic SNS para alertas de RDS"
  value       = aws_sns_topic.rds_alerts.arn
}

output "db_parameter_group_name" {
  description = "Nombre del parameter group de PostgreSQL"
  value       = aws_db_parameter_group.postgres15.name
}
