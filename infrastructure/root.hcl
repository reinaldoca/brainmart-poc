# ??????????????????????????????????????????????????????????????????????????????
# infrastructure/terragrunt.hcl ? ARCHIVO ROOT
#
# PROPO?SITO: Este es el punto de entrada de TODA la infraestructura.
# Define UNA SOLA VEZ: backend S3, providers AWS, y variables globales.
# Todos los mo?dulos hijo heredan esta configuracio?n via find_in_parent_folders().
#
# PRINCIPIO DRY (Don't Repeat Yourself):
#   - Backend S3 definido aqui? ? no se repite en ningu?n mo?dulo
#   - Provider con assume_role ? no se repite en ningu?n mo?dulo
#   - Tags comunes ? heredados automa?ticamente por todos los mo?dulos
#
# MULTI-CUENTA: Terragrunt asume el rol BrainmartTerragruntRole en cada
# cuenta usando sts:AssumeRole. El rol fue creado por el StackSet de Capa 0.
#
# CUMPLIMIENTO: FDA 21 CFR Part 11 ?11.10(k) - Control de cambios de IaC
# ??????????????????????????????????????????????????????????????????????????????

# ?? Leer configuraciones de cuenta y regio?n desde archivos HCL locales ??
# Cada ambiente (dev/staging/prod) tiene su propio account.hcl y region.hcl
# Terragrunt los busca hacia arriba en el a?rbol de directorios
locals {
  # Lee el account.hcl ma?s cercano en el a?rbol (ej: environments/dev/account.hcl)
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))

  # Lee el region.hcl ma?s cercano (ej: environments/dev/region.hcl)
  region_vars = read_terragrunt_config(find_in_parent_folders("region.hcl"))

  # Extrae los valores concretos de los archivos HCL
  account_id   = local.account_vars.locals.account_id
  account_name = local.account_vars.locals.account_name
  aws_region   = local.region_vars.locals.aws_region

  # ?? Tags globales obligatorios para TODOS los recursos ??
  # Checkov custom policy verifica que estos tags existen en todo recurso.
  # FDA 21 CFR Part 11: los recursos deben ser identificables y trazables.
  # Los valores base se definen aqui?; cada ambiente puede sobreescribir
  # 'Environment' y 'ComplianceLevel' en su terragrunt.hcl.
  common_tags = {
    Project         = "brainmart"
    Owner           = "devsecops-team@brainmart.health"
    ManagedBy       = "Terragrunt"
    ComplianceLevel = "FDA-21CFR11-GCP-ALCOA-GDPR"
    CostCenter      = "clinical-trials-platform"
    # Environment se agrega desde account.hcl de cada ambiente
  }
}

# ??????????????????????????????????????????????????????????????????????????????
# BACKEND S3 ? Definido UNA SOLA VEZ
#
# El estado de Terraform se guarda en S3 con:
#   - Cifrado KMS (no SSE-S3 gene?rico): los archivos de estado contienen
#     recursos sensibles (ARNs, IDs) que deben estar protegidos
#   - DynamoDB para locking: previene que dos pipelines modifiquen el mismo
#     estado simulta?neamente (race condition)
#   - Versionado habilitado: permite rollback del estado si algo sale mal
#   - Clave del estado = path relativo del mo?dulo: cada mo?dulo tiene su
#     propio archivo de estado aislado
# ??????????????????????????????????????????????????????????????????????????????
remote_state {
  backend = "s3"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    # El bucket incluye el account_id y la regio?n para evitar colisiones
    # entre ambientes (dev/staging/prod tienen buckets separados)
    bucket = "brainmart-tfstate-${local.account_id}-${local.aws_region}"

    # La key usa el path relativo del mo?dulo, creando una jerarqui?a:
    # ej: environments/dev/network/terraform.tfstate
    #     environments/dev/database/terraform.tfstate
    key = "${path_relative_to_include()}/terraform.tfstate"

    region = local.aws_region

    # Terraform 1.10+: use_lockfile reemplaza dynamodb_table para locking.
    # El lockfile se guarda junto al state en S3 (no requiere DynamoDB).
    use_lockfile = true

    # CRI?TICO: el estado de Terraform contiene informacio?n sensible
    # (connection strings, ARNs, etc.) ? DEBE estar cifrado
    encrypt = true

    # KMS CMK creada por infrastructure/bootstrap/main.tf (aws_kms_alias.tfstate).
    # El bootstrap se ejecuta UNA VEZ antes del primer deploy via job bootstrap-infra.
    # Ver: .github/workflows/ci-cd.yml -> job bootstrap-infra
    kms_key_id = "alias/brainmart-tfstate-key-${local.aws_region}"

    # Prevenir acceso pu?blico al bucket de estado (obligatorio)
    skip_bucket_accesslogging = false
    skip_bucket_root_access   = true
    skip_bucket_ssencryption  = false
    skip_bucket_versioning    = false
  }
}

# ??????????????????????????????????????????????????????????????????????????????
# GENERATE PROVIDER ? Definido UNA SOLA VEZ
#
# Genera el archivo provider.tf en cada mo?dulo automa?ticamente.
# Usa assume_role para autenticacio?n multi-cuenta SIN credenciales esta?ticas.
#
# FLUJO DE AUTENTICACIO?N:
#   1. Pipeline CI/CD tiene permisos en la cuenta Shared-Services
#   2. Terragrunt asume BrainmartTerragruntRole en la cuenta objetivo
#   3. Terraform opera con los permisos del rol asumido
#   ? No hay AWS_ACCESS_KEY_ID/SECRET de larga duracio?n en ningu?n lugar
# ??????????????????????????????????????????????????????????????????????????????
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"

  contents = <<-EOF
    # Este archivo fue generado automa?ticamente por Terragrunt
    # NO editar manualmente ? editar el root terragrunt.hcl

    # Provider primario: regio?n donde Terragrunt esta? operando actualmente
    provider "aws" {
      region = "${local.aws_region}"

      # Asumir el rol en la cuenta objetivo (multi-cuenta sin credenciales esta?ticas)
      # Este rol fue creado por el StackSet de Capa 0
      assume_role {
        role_arn     = "arn:aws:iam::${local.account_id}:role/BrainmartTerragruntRole"
        session_name = "Terragrunt-${local.account_name}-${local.aws_region}"
        # ExternalId debe coincidir con el configurado en el StackSet de IAM
        external_id  = "brainmart-terragrunt-${local.account_id}"
      }

      # Tags por defecto: se aplican a TODOS los recursos creados por este provider
      # Esto garantiza que incluso si un mo?dulo olvida agregar tags,
      # los tags de compliance mi?nimos siempre estara?n presentes
      default_tags {
        tags = merge(${jsonencode(local.common_tags)}, {
          Environment = "${local.account_name}"
        })
      }
    }

    # Provider para us-east-1 (necesario para recursos globales como ACM, WAF)
    # AWS requiere que los certificados ACM para CloudFront este?n en us-east-1
    provider "aws" {
      alias  = "us_east_1"
      region = "us-east-1"

      assume_role {
        role_arn     = "arn:aws:iam::${local.account_id}:role/BrainmartTerragruntRole"
        session_name = "Terragrunt-${local.account_name}-us-east-1-global"
        external_id  = "brainmart-terragrunt-${local.account_id}"
      }

      default_tags {
        tags = merge(${jsonencode(local.common_tags)}, {
          Environment = "${local.account_name}"
        })
      }
    }

    # Provider para eu-west-1 (Disaster Recovery y GDPR Data Residency)
    # Usado por: mo?dulo de database (re?plica cross-region), mo?dulo de network (DR VPC)
    provider "aws" {
      alias  = "eu_west_1"
      region = "eu-west-1"

      assume_role {
        role_arn     = "arn:aws:iam::${local.account_id}:role/BrainmartTerragruntRole"
        session_name = "Terragrunt-${local.account_name}-eu-west-1-dr"
        external_id  = "brainmart-terragrunt-${local.account_id}"
      }

      default_tags {
        tags = merge(${jsonencode(local.common_tags)}, {
          Environment = "${local.account_name}"
          Region      = "eu-west-1"
          Purpose     = "DR-GDPR"
        })
      }
    }

    # Provider random: para generar sufijos u?nicos en nombres de recursos
    provider "random" {}

    # Provider null: para ejecutar scripts locales (ej: cargar audit-triggers.sql)
    provider "null" {}
  EOF
}

# ??????????????????????????????????????????????????????????????????????????????
# INPUTS GLOBALES ? Variables heredadas por TODOS los mo?dulos hijo
#
# Estos inputs esta?n disponibles en todos los mo?dulos sin necesidad de
# repetirlos. Cada mo?dulo puede sobreescribir o agregar sus propios inputs.
# ??????????????????????????????????????????????????????????????????????????????
inputs = {
  # Identidad de la cuenta y regio?n
  aws_region   = local.aws_region
  account_id   = local.account_id
  environment  = local.account_name

  # Identificadores del proyecto (usados en nombres de recursos y tags)
  project      = "brainmart"
  owner        = "devsecops-team@brainmart.health"

  # Nivel de compliance: define el set de controles que aplica
  # Los mo?dulos usan este valor para decidir configuraciones:
  # ej: compliance_level == "prod" ? habilita Multi-AZ obligatorio
  compliance_level = "FDA-21CFR11-GCP-ALCOA-GDPR"

  # Tags comunes: los mo?dulos los mergean con sus propios tags
  common_tags = merge(local.common_tags, {
    Environment = local.account_name
  })

  # Configuracio?n de regiones
  primary_region = "us-east-1"
  dr_region      = "eu-west-1"

  # Nombre del proyecto para construir nombres de recursos
  # Convencio?n: brainmart-{ambiente}-{recurso}
  # ej: brainmart-dev-vpc, brainmart-prod-rds-main
  name_prefix = "brainmart-${local.account_name}"
}
