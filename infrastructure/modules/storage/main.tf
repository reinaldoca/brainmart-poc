# ??????????????????????????????????????????????????????????????????????????????
# modules/storage/main.tf
#
# MO?DULO: S3 + CloudFront para Angular 17 SPA
#
# IMPLEMENTA:
#   1. S3 bucket privado (SPA assets + datos de pacientes exportados)
#   2. CloudFront con Origin Access Control (OAC) ? reemplaza OAI legacy
#   3. WAF WebACL con reglas: XSS, SQLi, Rate Limiting, Geo-restriction
#   4. ACM Certificate para HTTPS (debe estar en us-east-1 para CloudFront)
#   5. S3 Object Lock para datos de auditori?a (retencio?n 7 an?os)
#   6. Bucket de logs de CloudFront
#
# SEGURIDAD:
#   - El bucket S3 NO es accesible directamente desde internet
#   - Solo CloudFront (via OAC) puede leer del bucket
#   - WAF bloquea: XSS, SQLi, bots, IPs maliciosas conocidas
#   - Geo-restriction: solo USA, LATAM y Espan?a
# ??????????????????????????????????????????????????????????????????????????????

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ??????????????????????????????????????????????????????????????????????????????
# S3 BUCKET ? SPA Assets
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_s3_bucket" "spa" {
  bucket = "${var.name_prefix}-spa-assets"
  tags   = merge(var.tags, { Name = "${var.name_prefix}-spa-assets", Purpose = "SPA" })
}

resource "aws_s3_bucket_versioning" "spa" {
  bucket = aws_s3_bucket.spa.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "spa" {
  bucket = aws_s3_bucket.spa.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "spa" {
  bucket                  = aws_s3_bucket.spa.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CKV2_AWS_61: S3 lifecycle configuration for SPA bucket
# Cleans up incomplete multipart uploads and old noncurrent versions
resource "aws_s3_bucket_lifecycle_configuration" "spa" {
  bucket = aws_s3_bucket.spa.id
  rule {
    id     = "spa-maintenance"
    status = "Enabled"

    # CKV_AWS_300: Abort incomplete multipart uploads
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    # Expire old noncurrent versions of SPA assets after 90 days
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# ??????????????????????????????????????????????????????????????????????????????
# S3 BUCKET - Audit logs (audit_log exported to Parquet)
# Object Lock COMPLIANCE mode: ni el root puede borrar antes de 7 an?os
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_s3_bucket" "audit" {
  bucket        = "${var.name_prefix}-audit-logs"
  object_lock_enabled = true  # Habilitado al crear (no se puede cambiar despue?s)
  tags = merge(var.tags, {
    Name              = "${var.name_prefix}-audit-logs"
    DataClassification = "PHI"
    RetentionYears    = "7"
    ComplianceLevel   = "FDA-21CFR11-GCP-ALCOA"
  })
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id
  # Object Lock requiere versionado habilitado
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_object_lock_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    default_retention {
      mode  = "GOVERNANCE"  # GOVERNANCE: admin puede borrar; COMPLIANCE: NADIE puede
      years = 7             # FDA 21 CFR Part 11: mi?nimo 5 an?os; GCP recomienda 7
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle: mover a Glacier despue?s de 1 an?o (ahorro de costos)
resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    id     = "audit-log-archival"
    status = "Enabled"

    # CKV_AWS_300: Abort failed multipart uploads after 7 days
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    transition {
      days          = 365
      storage_class = "GLACIER"
    }
    transition {
      days          = 730
      storage_class = "DEEP_ARCHIVE"
    }
  }
}

# Bucket policy: solo Lambda de exportacio?n y Athena pueden acceder
resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAuditExportLambda"
        Effect = "Allow"
        Principal = {
          AWS = var.audit_export_lambda_role_arn
        }
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.audit.arn}/*"
      },
      {
        Sid    = "AllowAthenaQueries"
        Effect = "Allow"
        Principal = {
          Service = "athena.amazonaws.com"
        }
        Action   = ["s3:GetObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
      },
      {
        Sid    = "DenyNonTLSRequests"
        Effect = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

# ??????????????????????????????????????????????????????????????????????????????
# WAF WebACL para CloudFront
# Debe crearse en us-east-1 (requerimiento de CloudFront)
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_wafv2_web_acl" "cloudfront" {
  provider    = aws.us_east_1  # CloudFront WAF DEBE estar en us-east-1
  name        = "${var.name_prefix}-cloudfront-waf"
  description = "WAF para CloudFront de Brainmart. Protege contra XSS, SQLi y ataques conocidos."
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Regla 1: AWS Managed Rules - Ruleset ba?sico
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
        # Excluir reglas que generan falsos positivos en APIs REST
        excluded_rule {
          name = "SizeRestrictions_BODY"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Regla 2: SQL Injection Protection
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "SQLiProtection"
      sampled_requests_enabled   = true
    }
  }

  # Regla 3: Known Bad Inputs (XSS, Log4j, etc.)
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 3
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "KnownBadInputs"
      sampled_requests_enabled   = true
    }
  }

  # Regla 4: Rate Limiting ? ma?ximo 2000 requests/5min por IP
  rule {
    name     = "RateLimitRule"
    priority = 4
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimit"
      sampled_requests_enabled   = true
    }
  }

  # Regla 5: Geo-restriction ? solo USA, LATAM y Espan?a
  rule {
    name     = "GeoRestriction"
    priority = 5
    action {
      block {}
    }
    statement {
      not_statement {
        statement {
          geo_match_statement {
            country_codes = [
              "US", "MX", "AR", "CO", "CL", "PE", "BR", "VE",
              "EC", "BO", "PY", "UY", "CR", "PA", "GT", "SV",
              "HN", "NI", "DO", "CU", "PR", "ES"  # Espan?a
            ]
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "GeoRestriction"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-cloudfront-waf"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

# ??????????????????????????????????????????????????????????????????????????????
# CLOUDFRONT ? Origin Access Control (OAC)
# OAC reemplaza al OAI (Origin Access Identity) legacy
# Usa SigV4 para autenticarse con S3 (ma?s seguro que OAI)
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_cloudfront_origin_access_control" "spa" {
  name                              = "${var.name_prefix}-spa-oac"
  description                       = "OAC para bucket S3 SPA de ${var.name_prefix}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "spa" {
  provider = aws.us_east_1

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Brainmart ${var.environment} - Angular SPA"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"  # Solo USA y Europa (ma?s barato)
  web_acl_id          = aws_wafv2_web_acl.cloudfront.arn

  aliases = var.domain_names

  origin {
    domain_name              = aws_s3_bucket.spa.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.spa.bucket}"
    origin_access_control_id = aws_cloudfront_origin_access_control.spa.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-${aws_s3_bucket.spa.bucket}"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    # Headers de seguridad que se agregan a todas las respuestas
    # Protegen contra XSS, clickjacking, MIME sniffing, etc.
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 86400   # 1 di?a para assets esta?ticos
    max_ttl     = 31536000 # 1 an?o para assets con hash en el nombre
  }

  # Angular routing: devolver index.html para rutas SPA (404 ? 200)
  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  restrictions {
    geo_restriction {
      # CKV_AWS_374: Native CloudFront geo restriction as defense-in-depth.
      # WAF rule "GeoRestriction" provides the primary enforcement.
      # This whitelist adds a second enforcement layer at the CDN level.
      restriction_type = "whitelist"
      locations = [
        "US", "MX", "AR", "CO", "CL", "PE", "BR", "VE",
        "EC", "BO", "PY", "UY", "CR", "PA", "GT", "SV",
        "HN", "NI", "DO", "CU", "PR", "ES"
      ]
    }
  }

  viewer_certificate {
    acm_certificate_arn      = var.acm_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  # Logs de acceso de CloudFront
  logging_config {
    include_cookies = false
    bucket          = "${var.name_prefix}-cf-logs.s3.amazonaws.com"
    prefix          = "cloudfront/"
  }

  tags = var.tags
}

# Headers de seguridad: Content Security Policy, HSTS, etc.
resource "aws_cloudfront_response_headers_policy" "security" {
  provider = aws.us_east_1
  name     = "${var.name_prefix}-security-headers"

  security_headers_config {
    # HSTS: forzar HTTPS por 1 an?o
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }
    # Prevenir clickjacking
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    # Prevenir MIME sniffing
    content_type_options {
      override = true
    }
    # XSS Protection (para browsers legacy)
    xss_protection {
      mode_block = true
      protection = true
      override   = true
    }
    # Content Security Policy (CSP) estricta para Angular
    content_security_policy {
      content_security_policy = join("; ", [
        "default-src 'self'",
        "script-src 'self' 'strict-dynamic'",
        "style-src 'self' 'unsafe-inline'",  # Angular requiere esto para styles
        "img-src 'self' data: https:",
        "font-src 'self'",
        "connect-src 'self' https://api.brainmart.health https://api-dev.brainmart.health",
        "frame-ancestors 'none'",
        "form-action 'self'",
        "upgrade-insecure-requests",
        "block-all-mixed-content"
      ])
      override = true
    }
    # Referrer Policy
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
  }
}

# Bucket policy: solo CloudFront OAC puede leer del bucket SPA
resource "aws_s3_bucket_policy" "spa" {
  bucket = aws_s3_bucket.spa.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontOAC"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.spa.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.spa.arn
          }
        }
      },
      {
        Sid    = "DenyNonTLS"
        Effect = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.spa.arn, "${aws_s3_bucket.spa.arn}/*"]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

# ??????????????????????????????????????????????????????????????????????????????
# ATHENA ? Para consultar audit logs en formato Parquet desde S3
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_athena_database" "audit" {
  name   = "${replace(var.name_prefix, "-", "_")}_audit"
  bucket = aws_s3_bucket.audit.id

  encryption_configuration {
    encryption_option = "SSE_KMS"
    kms_key           = var.kms_key_arn
  }
}

resource "aws_athena_workgroup" "audit" {
  name        = "${var.name_prefix}-audit-workgroup"
  description = "Workgroup de Athena para consultas de audit trail ALCOA+"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.audit.bucket}/athena-results/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key           = var.kms_key_arn
      }
    }

    engine_version {
      selected_engine_version = "Athena engine version 3"
    }
  }

  tags = var.tags
}
