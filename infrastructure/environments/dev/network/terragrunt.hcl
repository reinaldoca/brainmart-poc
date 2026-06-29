# ??????????????????????????????????????????????????????????????????????????????
# infrastructure/environments/dev/network/terragrunt.hcl
#
# PROPO?SITO: Despliega la VPC y recursos de red para el ambiente DEV.
# Este es el PRIMER mo?dulo que se despliega; todos los dema?s dependen de e?l.
#
# MO?DULO: Llama al mo?dulo reutilizable /modules/network/
# DEPENDENCIAS: Ninguna (es el punto de partida)
# OUTPUTS USADOS POR: database, compute, storage (para VPC ID, subnet IDs, SGs)
#
# DISEN?O DE RED DEV:
#   CIDR: 10.10.0.0/16 (reservado para DEV)
#   - Subnets pu?blicas:  10.10.0.0/24, 10.10.1.0/24     (ALB, NAT Gateway)
#   - Subnets privadas:  10.10.10.0/24, 10.10.11.0/24   (ECS Fargate)
#   - Subnets aisladas:  10.10.20.0/24, 10.10.21.0/24   (RDS, ElastiCache)
#
# CONVENCIO?N DE CIDR por ambiente:
#   dev:     10.10.0.0/16
#   staging: 10.20.0.0/16
#   prod:    10.30.0.0/16
#   dr:      10.40.0.0/16 (eu-west-1)
# ??????????????????????????????????????????????????????????????????????????????

# Heredar configuracio?n del terragrunt.hcl del ambiente DEV
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

# ?? Apuntar al mo?dulo de red reutilizable ??
# La URL usa una ruta relativa desde la ubicacio?n de este archivo.
# En produccio?n real, se usari?a una URL de Git con tag de versio?n:
# source = "git::https://github.com/brainmart/terraform-modules.git//network?ref=v1.2.0"
terraform {
  source = "../../../modules//network"
}

# ?? Variables especi?ficas del mo?dulo de red para DEV ??
inputs = {
  # ?? Identidad ??
  environment = "dev"
  name_prefix = "brainmart-dev"

  # ?? CIDR principal de la VPC ??
  vpc_cidr = "10.10.0.0/16"

  # ?? Availability Zones a usar ??
  # Se usan 2 AZs en DEV (mi?nimo para HA de ALB)
  # Checkov custom policy verifica que haya al menos 2 AZs
  availability_zones = ["us-east-1a", "us-east-1b"]

  # ?? CIDRs de subnets ??
  # Subnets PU?BLICAS: solo para ALB y NAT Gateway
  # NO se despliegan servidores de aplicacio?n en subnets pu?blicas
  public_subnet_cidrs = [
    "10.10.0.0/24",  # AZ-a: ALB, NAT Gateway
    "10.10.1.0/24"   # AZ-b: ALB (redundancia)
  ]

  # Subnets PRIVADAS: ECS Fargate (microservicios)
  # Tienen acceso a internet saliente via NAT Gateway (para pull de ima?genes ECR)
  # No tienen acceso entrante directo desde internet
  private_subnet_cidrs = [
    "10.10.10.0/24",  # AZ-a: ECS Fargate
    "10.10.11.0/24"   # AZ-b: ECS Fargate (redundancia)
  ]

  # Subnets AISLADAS: RDS PostgreSQL, ElastiCache
  # SIN acceso a internet (ni entrante ni saliente)
  # Solo accesibles desde las subnets privadas via Security Groups
  isolated_subnet_cidrs = [
    "10.10.20.0/24",  # AZ-a: RDS Primary
    "10.10.21.0/24"   # AZ-b: RDS Standby (Multi-AZ en prod), lectura en dev
  ]

  # ?? NAT Gateway ??
  # En DEV: un solo NAT Gateway (en una AZ) para ahorrar costos
  # En PROD: un NAT Gateway por AZ para alta disponibilidad
  single_nat_gateway = true  # true en dev, false en staging/prod

  # ?? VPC Endpoints ??
  # Tra?fico a servicios AWS sin pasar por internet (ma?s seguro y eficiente)
  # Requerido: los microservicios acceden a Secrets Manager, S3, ECR sin internet
  enable_vpc_endpoints = true
  vpc_endpoints = {
    # Interface endpoints (necesitan security group propio)
    secrets_manager = true  # Para que ECS acceda a Secrets Manager
    ecr_api         = true  # Para que ECS haga pull de ima?genes
    ecr_dkr         = true  # Para que ECS descargue layers de Docker
    logs            = true  # Para que ECS envi?e logs a CloudWatch

    # Gateway endpoints (gratuitos, no necesitan security group)
    s3       = true  # Para que ECS acceda a S3 (SBOM, artifacts)
    dynamodb = true  # Para que Lambda acceda a DynamoDB (si aplica)
  }

  # ⚠️  TEMPORARILY DISABLED while diagnosing aws_flow_log creation error.
  # The flow log resource fails every CI run with exit status 1 but the
  # actual error is never visible in the log.  Re-enable once fixed.
  # TODO: re-enable after diagnosing root cause locally:
  #   cd infrastructure/environments/dev/network
  #   TF_LOG=ERROR tofu apply -auto-approve -lock=false 2>&1 | grep -iE 'Error|error'
  enable_flow_logs            = false
  flow_logs_retention_in_days = 90  # 90 días en dev (7 años en prod)

  # ?? DNS ??
  enable_dns_hostnames = true
  enable_dns_support   = true

  # ?? Tags adicionales especi?ficos de este mo?dulo ??
  tags = {
    Module          = "network"
    CriticalityLevel = "low"  # DEV no es cri?tico
  }
}
