variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Ambiente debe ser: dev, staging o prod"
  }
}

variable "name_prefix" {
  type        = string
  description = "Prefijo para nombres de recursos (ej: brainmart-dev)"
}

variable "engine" {
  type    = string
  default = "postgres"
}

variable "engine_version" {
  type    = string
  default = "15.6"
}

variable "instance_class" {
  type        = string
  description = "Clase de instancia RDS. Dev: db.t3.medium, Prod: db.r6g.xlarge"
}

variable "storage_type" {
  type    = string
  default = "gp3"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "max_allocated_storage" {
  type        = number
  default     = 100
  description = "Ma?ximo GB para autoscaling de almacenamiento"
}

variable "multi_az" {
  type        = bool
  description = "Multi-AZ para alta disponibilidad. OBLIGATORIO en produccio?n (OPA policy)."
}

variable "db_name" {
  type = string
}

variable "username" {
  type        = string
  description = "Nombre del usuario master de la BD (la contrasen?a se genera automa?ticamente)"
}

variable "db_subnet_group_name" {
  type        = string
  description = "DB Subnet Group (output del mo?dulo network)"
}

variable "rds_security_group_id" {
  type        = string
  description = "Security Group para RDS (output del mo?dulo network)"
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnets para la Lambda de exportacio?n de audit log"
}

variable "allowed_cidr_blocks" {
  type        = list(string)
  description = "CIDRs permitidos para acceder a la BD (VPC CIDR)"
}

variable "backup_retention_period" {
  type        = number
  description = <<-EOT
    Di?as de retencio?n de backups automa?ticos.
    GCP ICH E6(R2) requiere MI?NIMO 35 di?as para datos de ensayos cli?nicos.
    OPA policy verifica que prod tenga >= 35 di?as.
    Dev puede tener menos (7 di?as recomendado para ahorrar costos).
  EOT
  validation {
    condition     = var.backup_retention_period >= 1 && var.backup_retention_period <= 35
    error_message = "backup_retention_period debe estar entre 1 y 35 di?as"
  }
}

variable "backup_window" {
  type    = string
  default = "03:00-04:00"
}

variable "maintenance_window" {
  type    = string
  default = "sun:04:00-sun:05:00"
}

variable "enable_pitr" {
  type    = bool
  default = true
}

variable "storage_encrypted" {
  type        = bool
  default     = true
  description = "SIEMPRE true. Checkov policy y SCP de Capa 0 lo verifican."
  validation {
    condition     = var.storage_encrypted == true
    error_message = "storage_encrypted DEBE ser true. Requesito FDA 21 CFR Part 11 ?11.10(c)"
  }
}

variable "kms_key_id" {
  type        = string
  default     = ""
  description = "ARN de KMS CMK externa. Si esta? vaci?o, se crea una nueva CMK."
}

variable "performance_insights_enabled" {
  type    = bool
  default = true
}

variable "performance_insights_retention_period" {
  type    = number
  default = 7
}

variable "monitoring_interval" {
  type    = number
  default = 60
}

variable "monitoring_role_arn" {
  type    = string
  default = ""
}

variable "db_parameters" {
  type = list(object({
    name         = string
    value        = string
    apply_method = optional(string, "immediate")
  }))
  default = []
}

variable "enable_audit_triggers" {
  type    = bool
  default = true
}

variable "audit_trigger_tables" {
  type        = list(string)
  description = "Lista de tablas donde se instalan los triggers ALCOA+"
  default     = []
}

variable "enable_audit_export" {
  type    = bool
  default = true
}

variable "audit_export_bucket" {
  type        = string
  description = "Bucket S3 donde se exporta audit_log en formato Parquet"
  default     = ""
}

variable "audit_export_schedule" {
  type    = string
  default = "rate(1 hour)"
}

variable "deletion_protection" {
  type        = bool
  default     = true
  description = "true en produccio?n para prevenir borrado accidental de la BD"
}

variable "lambda_s3_bucket" {
  description = "S3 bucket containing the audit-export Lambda ZIP. Set by the CI/CD pipeline."
  type        = string
  default     = ""
}

variable "lambda_s3_key" {
  description = "S3 key of the audit-export Lambda ZIP."
  type        = string
  default     = "lambda/audit-export.zip"
}

variable "lambda_source_code_hash" {
  description = "base64-encoded SHA256 of the Lambda ZIP (for change detection)."
  type        = string
  default     = ""
}

variable "rotation_lambda_arn" {
  type        = string
  default     = ""
  description = "ARN of rotation Lambda for Secrets Manager (CKV2_AWS_57). Empty = no rotation."
}

variable "lambda_code_signing_config_arn" {
  type        = string
  default     = ""
  description = "ARN of Lambda code-signing config (CKV_AWS_272). Empty = skip for dev/POC."
}

variable "cost_center" {
  description = "Cost center for billing allocation. Use clinical trial ID (e.g. 'trial-NCT-2024-001')."
  type        = string
  default     = "clinical-trials-platform"
}

variable "tags" {
  type    = map(string)
  default = {}
}
