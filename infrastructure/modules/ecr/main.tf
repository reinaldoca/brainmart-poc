# ==============================================================================
# infrastructure/modules/ecr/main.tf
#
# PROPÓSITO: Crea repositorios ECR en la cuenta Shared Services.
#
# CICLO DE VIDA: Permanente. Los repositorios ECR se crean UNA SOLA VEZ
# y son compartidos por todos los ambientes (dev/staging/prod usan el
# mismo registro en la cuenta Shared Services).
#
# POR QUÉ AQUÍ Y NO EN compute/:
#   - Los módulos de compute son destruibles por ambiente.
#   - Las imágenes Docker son artefactos de larga duración.
#   - ECR es un servicio de la cuenta Shared Services, no de las cuentas
#     de aplicación (dev/staging/prod).
#   - Separar ECR de compute evita el problema de "huevo y gallina":
#     el build necesita ECR antes de que compute exista.
#
# SEGURIDAD:
#   - image_tag_mutability = IMMUTABLE: un tag no puede ser sobreescrito.
#     Esto garantiza que sha-<commit> siempre apunta a la misma imagen,
#     cumpliendo FDA 21 CFR Part 11 §11.10(e) - integridad de registros.
#   - scan_on_push = true: Detecta CVEs en cada imagen pusheada.
#   - encryption_type = KMS: Cifrado con CMK propia del registro.
#   - lifecycle_policy: Limita el número de imágenes no-tagged (evita
#     acumulación de imágenes huérfanas y reduce costos de almacenamiento).
# ==============================================================================

resource "aws_ecr_repository" "this" {
  for_each = var.repositories

  name                 = each.value.name
  image_tag_mutability = "IMMUTABLE"  # FDA 21 CFR Part 11: inmutabilidad de registros

  # Escaneo automático de vulnerabilidades en cada push
  image_scanning_configuration {
    scan_on_push = true
  }

  # Cifrado KMS (más seguro que AES-256 por defecto)
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn != "" ? var.kms_key_arn : null
  }

  tags = merge(var.tags, {
    Name       = each.value.name
    Service    = each.key
    Immutable  = "true"
  })
}

# ------------------------------------------------------------------------------
# Lifecycle policy: mantener las últimas N imágenes tagged (semver)
# y limpiar imágenes untagged automáticamente después de 14 días.
# Reduce costos de almacenamiento y mantiene el registro limpio.
# ------------------------------------------------------------------------------
resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        # Regla 1: Mantener las últimas 30 imágenes con tag semver (releases)
        rulePriority = 1
        description  = "Keep last 30 semver-tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "1.", "2.", "3."]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = { type = "expire" }
      },
      {
        # Regla 2: Mantener las últimas 10 imágenes con tag sha-
        rulePriority = 2
        description  = "Keep last 10 sha-tagged images for rollback"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      },
      {
        # Regla 3: Limpiar imágenes sin tag después de 14 días
        # (imágenes huérfanas de builds fallidos)
        rulePriority = 3
        description  = "Expire untagged images after 14 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# Repository policy: solo la cuenta Shared Services y los roles de CI/CD
# y de ECS Task Execution pueden hacer pull/push.
# Principio de mínimo privilegio.
# ------------------------------------------------------------------------------
resource "aws_ecr_repository_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCICDPush"
        Effect = "Allow"
        Principal = {
          AWS = var.cicd_role_arns
        }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
          "ecr:GetRepositoryPolicy",
          "ecr:ListImages",
          "ecr:DeleteRepository",
          "ecr:BatchDeleteImage",
          "ecr:SetRepositoryPolicy",
          "ecr:DeleteRepositoryPolicy"
        ]
      },
      {
        Sid    = "AllowECSPull"
        Effect = "Allow"
        Principal = {
          AWS = var.ecs_task_execution_role_arns
        }
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability"
        ]
      }
    ]
  })
}
