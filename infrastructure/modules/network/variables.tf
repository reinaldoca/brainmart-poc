# ??????????????????????????????????????????????????????????????????????????????
# modules/network/variables.tf
# Variables del mo?dulo de red de Brainmart
# ??????????????????????????????????????????????????????????????????????????????

variable "environment" {
  description = "Nombre del ambiente (dev, staging, prod)"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod", "shared-services"], var.environment)
    error_message = "El ambiente debe ser: dev, staging, prod o shared-services"
  }
}

variable "name_prefix" {
  description = "Prefijo para nombres de recursos. Convencio?n: brainmart-{ambiente}"
  type        = string
}

variable "vpc_cidr" {
  description = <<-EOT
    CIDR principal de la VPC.
    Convencio?n de CIDRs por ambiente:
      dev:     10.10.0.0/16
      staging: 10.20.0.0/16
      prod:    10.30.0.0/16
      dr:      10.40.0.0/16 (eu-west-1)
  EOT
  type        = string
  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "El CIDR de la VPC debe ser una direccio?n CIDR va?lida (ej: 10.10.0.0/16)"
  }
}

variable "availability_zones" {
  description = <<-EOT
    Lista de Availability Zones a usar.
    Mi?nimo 2 AZs para cumplir con:
    - Checkov custom policy: verifica >= 2 AZs
    - ALB requiere >= 2 AZs
    - RDS Multi-AZ requiere >= 2 AZs
  EOT
  type        = list(string)
  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "Se requieren al menos 2 Availability Zones (Checkov policy: check_vpc_multi_az)"
  }
}

variable "public_subnet_cidrs" {
  description = "CIDRs de subnets pu?blicas (para ALB y NAT Gateway). Una por AZ."
  type        = list(string)
  validation {
    condition     = length(var.public_subnet_cidrs) >= 2
    error_message = "Se requieren al menos 2 subnets pu?blicas (una por AZ para HA del ALB)"
  }
}

variable "private_subnet_cidrs" {
  description = "CIDRs de subnets privadas (para microservicios ECS Fargate). Una por AZ."
  type        = list(string)
  validation {
    condition     = length(var.private_subnet_cidrs) >= 2
    error_message = "Se requieren al menos 2 subnets privadas (una por AZ para HA de ECS)"
  }
}

variable "isolated_subnet_cidrs" {
  description = <<-EOT
    CIDRs de subnets aisladas (para RDS PostgreSQL).
    SIN acceso a internet. Solo accesibles desde subnets privadas.
    Requiere al menos 2 para que RDS pueda ser Multi-AZ.
  EOT
  type        = list(string)
  validation {
    condition     = length(var.isolated_subnet_cidrs) >= 2
    error_message = "Se requieren al menos 2 subnets aisladas para soporte Multi-AZ de RDS"
  }
}

variable "single_nat_gateway" {
  description = <<-EOT
    Si true: un solo NAT Gateway (dev/staging, ahorro de costos).
    Si false: un NAT Gateway por AZ (prod, alta disponibilidad).
    En produccio?n, la cai?da del NAT Gateway afecta a TODOS los microservicios
    de esa AZ si es compartido, por eso en prod se usa uno por AZ.
  EOT
  type        = bool
  default     = true
}

variable "enable_dns_hostnames" {
  description = "Habilitar hostnames DNS en la VPC (necesario para VPC Endpoints y Service Discovery)"
  type        = bool
  default     = true
}

variable "enable_dns_support" {
  description = "Habilitar soporte DNS en la VPC"
  type        = bool
  default     = true
}

variable "enable_vpc_endpoints" {
  description = "Habilitar VPC Endpoints para servicios AWS (ma?s seguro que ir por internet)"
  type        = bool
  default     = true
}

variable "vpc_endpoints" {
  description = <<-EOT
    Mapa de VPC Endpoints a habilitar.
    Cada key es el nombre del endpoint y el valor es true/false.
    Endpoints recomendados para Brainmart:
      secrets_manager: para que ECS lea credenciales sin internet
      ecr_api, ecr_dkr: para pull de ima?genes sin internet
      logs: para envi?o de logs sin internet
      s3: gateway gratuito para acceso a S3
      dynamodb: gateway gratuito para DynamoDB
  EOT
  type = object({
    secrets_manager = bool
    ecr_api         = bool
    ecr_dkr         = bool
    logs            = bool
    s3              = bool
  })
  default = {
    secrets_manager = true
    ecr_api         = true
    ecr_dkr         = true
    logs            = true
    s3              = true
  }
}

variable "enable_flow_logs" {
  description = <<-EOT
    Habilitar VPC Flow Logs.
    OBLIGATORIO: Config Rule de Capa 0 verifica que este? habilitado.
    Necesario para auditori?a forense y deteccio?n de exfiltracio?n de PHI.
  EOT
  type        = bool
  default     = true
}

variable "flow_logs_retention_in_days" {
  description = <<-EOT
    Retencio?n de VPC Flow Logs en CloudWatch Logs.
    Dev: 90 di?as; Prod: 2555 di?as (7 an?os, FDA 21 CFR Part 11)
  EOT
  type        = number
  default     = 90
  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545,
      731, 1096, 1827, 2192, 2557, 2922, 3288, 3653
    ], var.flow_logs_retention_in_days)
    error_message = "La retencio?n debe ser uno de los valores va?lidos de CloudWatch Logs"
  }
}

variable "kms_key_id" {
  description = "ARN or alias of KMS CMK to encrypt VPC Flow Logs CloudWatch group. Empty = no encryption."
  type        = string
  default     = ""
}

variable "tags" {
  description = <<-EOT
    Tags adicionales para todos los recursos del mo?dulo.
    Los tags de compliance (Environment, Project, Owner, ComplianceLevel)
    se heredan automa?ticamente del provider via default_tags en Terragrunt.
  EOT
  type        = map(string)
  default     = {}
}
