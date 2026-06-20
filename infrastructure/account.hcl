# ??????????????????????????????????????????????????????????????????????????????
# infrastructure/account.hcl
#
# PROPO?SITO: Mapeo centralizado de IDs de cuentas AWS y nombres de ambientes.
# Terragrunt lee este archivo desde el root terragrunt.hcl y desde cada
# mo?dulo via find_in_parent_folders("account.hcl").
#
# IMPORTANTE: Los account.hcl en cada ambiente (dev/staging/prod) sobreescriben
# los valores de este archivo para definir la cuenta correcta.
# Este archivo define los valores que aplican cuando se lee desde el ROOT
# y el mapeo global de todas las cuentas.
#
# SEGURIDAD: Los IDs de cuenta NO son secretos (aparecen en ARNs),
# pero tampoco deben ser hardcodeados en el co?digo de los mo?dulos.
# Este archivo centraliza el mapeo cuenta?nombre para que sea fa?cil
# actualizar cuando se crean nuevas cuentas.
# ??????????????????????????????????????????????????????????????????????????????

locals {
  # ?? Mapeo completo de cuentas de la organizacio?n ??
  # Cada entrada: nombre legible ? ID de cuenta AWS
  # Los IDs reales deben ser reemplazados con los de la organizacio?n Brainmart
  accounts = {
    # Cuenta donde se gestionan los recursos compartidos (ECR, CI/CD artifacts, etc.)
    shared-services = {
      account_id   = "111111111111"
      account_name = "shared-services"
      description  = "Cuenta de servicios compartidos: ECR, CI/CD, audit logs"
    }

    # Ambiente de desarrollo: para feature development
    dev = {
      account_id   = "222222222222"
      account_name = "dev"
      description  = "Ambiente de desarrollo para el equipo de Brainmart"
    }

    # Ambiente de staging: re?plica de produccio?n para pruebas finales
    staging = {
      account_id   = "333333333333"
      account_name = "staging"
      description  = "Ambiente de staging para validacio?n pre-produccio?n (GCP UAT)"
    }

    # Produccio?n: ambiente final con todos los controles habilitados
    prod = {
      account_id   = "444444444444"
      account_name = "prod"
      description  = "Ambiente de produccio?n: FDA 21 CFR Part 11 compliant"
    }
  }

  # ?? Valores del ambiente ACTUAL ??
  # Estos valores se sobreescriben en el account.hcl de cada subdirectorio.
  # El valor aqui? es el DEFAULT (se lee cuando no hay un account.hcl ma?s especi?fico)
  account_id   = "222222222222"  # Default: dev
  account_name = "dev"           # Default: dev

  # ?? Configuracio?n de la cuenta Master de la organizacio?n ??
  master_account_id = "000000000000"
  org_id            = "o-xxxxxxxxxxxx"

  # ?? ARN del rol Terragrunt en cada cuenta (creado por el StackSet IAM) ??
  # Construido dina?micamente para no hardcodear ARNs
  terragrunt_role_name = "BrainmartTerragruntRole"

  # ?? Cuenta de ECR: todas las cuentas hacen pull desde shared-services ??
  ecr_registry = "${local.accounts.shared-services.account_id}.dkr.ecr.us-east-1.amazonaws.com"
}
