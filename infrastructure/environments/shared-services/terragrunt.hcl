# ==============================================================================
# infrastructure/environments/shared-services/terragrunt.hcl
#
# PROPÓSITO: Provisionamiento de recursos compartidos por TODOS los ambientes.
#
# RECURSOS GESTIONADOS AQUÍ:
#   - ECR repositories (imágenes Docker — una vez, permanentes)
#   - S3 bucket para artifacts de CI/CD (SBOMs, reports)
#   - KMS keys compartidas
#
# CUÁNDO EJECUTAR:
#   Se ejecuta UNA SOLA VEZ al crear la cuenta Shared Services, y luego
#   cuando se añaden nuevos servicios (nuevos repositorios ECR).
#   NO se ejecuta en cada deploy de aplicación.
#
# DEPENDENCIAS: Ninguna (es el primer nivel de infraestructura).
# ==============================================================================

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "../../modules//ecr"
}

inputs = {
  repositories = {
    patient-service = {
      name = "brainmart/patient-service"
    }
    # Agregar nuevos servicios aquí cuando se incorporen al monorepo
    # patient-dashboard = {
    #   name = "brainmart/patient-dashboard"
    # }
  }

  # Roles de CI/CD con permiso de push
  # El rol GitHubActionsRole en la cuenta Shared Services
  cicd_role_arns = [
    "arn:aws:iam::${include.root.locals.account_id}:role/GitHubActionsRole",
  ]

  # Roles de ECS Task Execution en cuentas de aplicación (cross-account pull)
  ecs_task_execution_role_arns = [
    "arn:aws:iam::${var.dev_account_id}:role/brainmart-dev-ecs-task-execution",
    "arn:aws:iam::${var.staging_account_id}:role/brainmart-staging-ecs-task-execution",
    "arn:aws:iam::${var.prod_account_id}:role/brainmart-prod-ecs-task-execution",
  ]

  tags = merge(include.root.locals.common_tags, {
    Layer      = "shared-services"
    Persistent = "true"
  })
}
