# ??????????????????????????????????????????????????????????????????????????????
# environments/prod/dr-eu-west-1/terragrunt.hcl
#
# DISASTER RECOVERY en eu-west-1 (Irlanda)
# GDPR: datos de pacientes europeos tienen su re?plica en la UE
# RTO < 5 min, RPO < 30 segundos (ver runbook-failover.md)
# ??????????????????????????????????????????????????????????????????????????????

locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
}

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

# Sobrescribir la regio?n para este subdirectorio
generate "provider_override" {
  path      = "provider_region_override.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    # Override: este mo?dulo opera en eu-west-1 (DR)
    provider "aws" {
      region = "eu-west-1"
      assume_role {
        role_arn     = "arn:aws:iam::${local.account_vars.locals.account_id}:role/BrainmartTerragruntRole"
        session_name = "Terragrunt-prod-dr-eu-west-1"
        external_id  = "brainmart-terragrunt-${local.account_vars.locals.account_id}"
      }
      alias = "dr"
    }
  EOF
}

inputs = {
  environment = "prod"
  aws_region  = "eu-west-1"
  name_prefix = "brainmart-prod-dr"

  # Red DR: CIDR separado para evitar conflictos si se crea un VPC Peering
  vpc_cidr           = "10.40.0.0/16"
  availability_zones = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]

  public_subnet_cidrs   = ["10.40.0.0/24", "10.40.1.0/24", "10.40.2.0/24"]
  private_subnet_cidrs  = ["10.40.10.0/24", "10.40.11.0/24", "10.40.12.0/24"]
  isolated_subnet_cidrs = ["10.40.20.0/24", "10.40.21.0/24", "10.40.22.0/24"]

  single_nat_gateway          = false  # HA tambie?n en DR
  enable_vpc_endpoints        = true
  enable_flow_logs            = true
  flow_logs_retention_in_days = 2555

  # La BD DR es una Read Replica de la primaria en us-east-1
  # Cuando se promueve en DR, se vuelve primary independiente
  is_dr_replica   = true
  source_db_region = "us-east-1"

  # Taman?o igual a produccio?n para que el failover sea transparente
  instance_class   = "db.r6g.xlarge"
  desired_count    = 1  # Solo 1 task en standby; escala a 2 en failover

  tags = {
    Region           = "eu-west-1"
    Purpose          = "DisasterRecovery"
    GDPRDataResidency = "EU"
    CriticalityLevel = "critical"
  }
}
