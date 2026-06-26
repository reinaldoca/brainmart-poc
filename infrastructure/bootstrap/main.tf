# ==============================================================================
# infrastructure/bootstrap/main.tf
#
# PROPÓSITO: Crear los recursos prerequisito que TODOS los módulos Terraform
# necesitan ANTES de poder ejecutarse.
#
# PROBLEMA QUE RESUELVE (dependencia circular):
#   root.hcl requiere:  KMS key   → para cifrar el state en S3
#   root.hcl requiere:  S3 bucket → para guardar el state
#   root.hcl requiere:  DynamoDB  → para el state locking
#   ↑ Pero para crear estos con Terraform, necesitas... un backend S3 ✗
#
# SOLUCIÓN:
#   Este módulo usa backend LOCAL (terraform.tfstate en disco).
#   Se ejecuta UNA SOLA VEZ manualmente o desde el job bootstrap-infra del CI.
#   Después de ejecutarse, todos los demás módulos usan el backend S3 remoto.
#
# EJECUCIÓN:
#   cd infrastructure/bootstrap
#   terraform init
#   terraform apply -var="account_id=<ID>" -var="region=us-east-1"
#
# NO DESTRUIR: estos recursos son permanentes. Destruirlos hace que el
#              state de TODA la infraestructura sea inaccesible.
# ==============================================================================

terraform {
  # Backend LOCAL — no depende de S3 ni KMS (es el bootstrapper)
  # El tfstate de este módulo se guarda en el repo (o en un lugar seguro)
  backend "local" {
    path = "bootstrap.tfstate"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# ==============================================================================
# KMS KEY para cifrar el state de Terraform
# ==============================================================================
resource "aws_kms_key" "tfstate" {
  description             = "KMS key for Terraform state encryption - ${var.region}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = false

  # No custom policy: AWS applies the default key policy which grants
  # full access to the account root (arn:aws:iam::ACCOUNT_ID:root).
  # This avoids MalformedPolicyDocumentException during key creation.

  tags = {
    Name        = "brainmart-tfstate-key-${var.region}"
    Purpose     = "TerraformStateEncryption"
    ManagedBy   = "bootstrap"
    Environment = "shared-services"
  }
}

resource "aws_kms_alias" "tfstate" {
  name          = "alias/brainmart-tfstate-key-${var.region}"
  target_key_id = aws_kms_key.tfstate.key_id
}

# ==============================================================================
# S3 BUCKET para el state de Terraform
# ==============================================================================
resource "aws_s3_bucket" "tfstate" {
  bucket        = "brainmart-tfstate-${var.account_id}-${var.region}"
  force_destroy = false  # Nunca destruir accidentalmente el state

  tags = {
    Name        = "brainmart-tfstate-${var.account_id}-${var.region}"
    Purpose     = "TerraformState"
    ManagedBy   = "bootstrap"
    Environment = "shared-services"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"  # Permite rollback del state si algo sale mal
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tfstate.arn
    }
    bucket_key_enabled = true  # Reduce costos de KMS requests
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "cleanup-old-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90   # Mantener versiones antiguas 90 días para recovery
    }
  }
}

# ==============================================================================
# DYNAMODB TABLE para state locking
# ==============================================================================
resource "aws_dynamodb_table" "tfstate_lock" {
  name         = "brainmart-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"  # Sin capacidad provisionada = sin costo en idle
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  # Cifrado con la misma KMS key del state
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.tfstate.arn
  }

  # Point-in-time recovery por si se corrompe la tabla
  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name        = "brainmart-tfstate-lock"
    Purpose     = "TerraformStateLock"
    ManagedBy   = "bootstrap"
    Environment = "shared-services"
  }
}
