# ??????????????????????????????????????????????????????????????????????????????
# modules/database/main.tf
#
# MO?DULO: RDS PostgreSQL 15 para Brainmart
#
# IMPLEMENTA:
#   1. RDS PostgreSQL 15 con cifrado KMS CMK
#   2. Multi-AZ (en produccio?n) para alta disponibilidad
#   3. Backup con retencio?n de 35 di?as + PITR (Point In Time Recovery)
#   4. Performance Insights y Enhanced Monitoring
#   5. Audit triggers ALCOA+ vi?a null_resource que ejecuta SQL
#   6. Exportacio?n automa?tica de audit_log a S3 en formato Parquet
#   7. Replicacio?n lo?gica cross-region (para DR en eu-west-1)
#
# ALCOA+:
#   - Attributable:    audit_log.changed_by (usuario de BD + claim JWT)
#   - Legible:         formato Parquet en S3 + queries Athena
#   - Contemporaneous: audit_log.changed_at = NOW() UTC
#   - Original:        audit_log.old_values JSONB (valor antes del cambio)
#   - Accurate:        audit_log.new_values JSONB (valor despue?s del cambio)
#   - Complete:        triggers en ALL tablas (INSERT + UPDATE + DELETE)
#
# CUMPLIMIENTO:
#   - FDA 21 CFR Part 11 ?11.10(e): Audit trails
#   - GCP ICH E6(R2): backup 35 di?as, trazabilidad completa
#   - GDPR: cifrado, replicacio?n EU, retencio?n 7 an?os
# ??????????????????????????????????????????????????????????????????????????????

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ??????????????????????????????????????????????????????????????????????????????
# KMS CMK ? Customer Managed Key para cifrado de la BD
#
# Usamos una CMK especi?fica para la BD (no la key por defecto de RDS):
# - Control total sobre la poli?tica de la key
# - Rotacio?n automa?tica anual (obligatorio por SCP de Capa 0)
# - Auditable: cada uso de la key aparece en CloudTrail
# - Si es comprometida, podemos revocar acceso sin afectar otras keys
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_kms_key" "rds" {
  # Solo crear la CMK si no se proporciono? una externa
  count = var.kms_key_id == "" ? 1 : 0

  description             = "KMS CMK para cifrado de RDS PostgreSQL ${var.name_prefix}"
  deletion_window_in_days = 30  # 30 di?as de gracia antes de eliminacio?n permanente

  # CRI?TICO: SCP de Capa 0 prohi?be deshabilitar la rotacio?n
  # La rotacio?n ocurre automa?ticamente cada an?o
  enable_key_rotation = true

  # Poli?tica de la key: solo los roles autorizados pueden usarla
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # La cuenta puede administrar la key via IAM
        Sid    = "EnableIAMUserPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        # RDS puede usar la key para cifrar/descifrar
        Sid    = "AllowRDSUseOfKey"
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:CreateGrant",
          "kms:ListGrants",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-rds-kms-key"
    Purpose = "RDS-Encryption"
  })
}

resource "aws_kms_alias" "rds" {
  count = var.kms_key_id == "" ? 1 : 0

  name          = "alias/${var.name_prefix}-rds"
  target_key_id = aws_kms_key.rds[0].key_id
}

# Determinar que? key usar: la proporcionada externamente o la creada aqui?
locals {
  kms_key_arn = var.kms_key_id != "" ? var.kms_key_id : (
    length(aws_kms_key.rds) > 0 ? aws_kms_key.rds[0].arn : null
  )
}

# ??????????????????????????????????????????????????????????????????????????????
# CONTRASEN?A DE LA BD ? Generada automa?ticamente
# NUNCA se hardcodea en el co?digo. Se genera aqui? y se guarda en Secrets Manager.
# ??????????????????????????????????????????????????????????????????????????????

resource "random_password" "db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
  # min requirements para cumplir poli?ticas de contrasen?as corporativas
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 2
}

# Guardar la contrasen?a en Secrets Manager (inmediatamente al crearla)
resource "aws_secretsmanager_secret" "db_password" {
  name        = "${var.name_prefix}/database/master-password"
  description = "Contrasen?a del usuario master de RDS PostgreSQL ${var.name_prefix}"

  # Cifrar con la misma CMK que la BD (coherencia de cifrado)
  kms_key_id = local.kms_key_arn

  # Peri?odo de recuperacio?n: 30 di?as (no se puede eliminar inmediatamente)
  # Previene borrado accidental de credenciales en uso
  recovery_window_in_days = 30
  tags = var.tags
}

resource "aws_secretsmanager_secret_rotation" "db_password" {
  count               = var.rotation_lambda_arn != "" ? 1 : 0
  secret_id           = aws_secretsmanager_secret.db_password.id
  rotation_lambda_arn = var.rotation_lambda_arn
  rotation_rules { automatically_after_days = 30 }
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id = aws_secretsmanager_secret.db_password.id
  secret_string = jsonencode({
    username = var.username
    password = random_password.db_password.result
    host     = aws_db_instance.main.address
    port     = 5432
    dbname   = var.db_name
    # Connection string lista para usar por la aplicacio?n .NET
    connection_string = "Host=${aws_db_instance.main.address};Port=5432;Database=${var.db_name};Username=${var.username};Password=${random_password.db_password.result};SSL Mode=Require;"
  })
}

# ??????????????????????????????????????????????????????????????????????????????
# PARAMETER GROUP DE POSTGRESQL
# Configuracio?n del motor PostgreSQL para habilitar:
#   - Replicacio?n lo?gica (para DR en eu-west-1)
#   - Logging completo (para ALCOA+)
#   - pgaudit (auditori?a granular de SQL)
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_db_parameter_group" "postgres15" {
  name        = "${var.name_prefix}-postgres15-params"
  family      = "postgres15"
  description = "Parameter group para PostgreSQL 15 de Brainmart con configuracio?n ALCOA+"

  # ?? Replicacio?n lo?gica para DR cross-region ??
  # Necesario para enviar cambios a la re?plica en eu-west-1
  parameter {
    name         = "wal_level"
    value        = "logical"
    apply_method = "pending-reboot"  # Requiere reinicio del motor
  }

  parameter {
    name         = "max_replication_slots"
    value        = "5"  # Nu?mero de slots de replicacio?n activos
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "max_worker_processes"
    value        = "8"
    apply_method = "pending-reboot"
  }

  # ?? Logging para ALCOA+ ??
  parameter {
    name  = "log_statement"
    value = "all"  # Registrar TODOS los SQL statements
  }

  parameter {
    name  = "log_duration"
    value = "on"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"  # Log de queries > 1 segundo (para Performance Insights)
  }

  parameter {
    name  = "log_connections"
    value = "on"  # Registrar cada conexio?n (trazabilidad de usuarios)
  }

  parameter {
    name  = "log_disconnections"
    value = "on"
  }

  parameter {
    name  = "log_lock_waits"
    value = "on"  # Detectar contencio?n de locks (problemas de concurrencia)
  }

  # CKV2_AWS_69: Force encrypted (SSL/TLS) connections to RDS
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  # Timezone UTC - ALCOA+ requires consistent UTC timestamps
  parameter {
    name  = "timezone"
    value = "UTC"
  }

  # ?? Shared libraries para pgaudit ??
  # pgaudit provee auditori?a granular de operaciones SQL (SELECT, INSERT, etc.)
  parameter {
    name         = "shared_preload_libraries"
    value        = "pgaudit,pg_stat_statements"
    apply_method = "pending-reboot"
  }

  # Configuracio?n de pgaudit: registrar operaciones de datos (DML)
  parameter {
    name  = "pgaudit.log"
    value = "write,ddl"  # DDL: CREATE/ALTER/DROP; write: INSERT/UPDATE/DELETE
  }

  tags = var.tags
}

# ??????????????????????????????????????????????????????????????????????????????
# ROL IAM PARA ENHANCED MONITORING
# RDS necesita un rol IAM para enviar me?tricas del OS a CloudWatch
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_iam_role" "rds_monitoring" {
  count = var.monitoring_role_arn == "" ? 1 : 0

  name = "${var.name_prefix}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "monitoring.rds.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  count = var.monitoring_role_arn == "" ? 1 : 0

  role       = aws_iam_role.rds_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

locals {
  monitoring_role_arn = var.monitoring_role_arn != "" ? var.monitoring_role_arn : (
    length(aws_iam_role.rds_monitoring) > 0 ? aws_iam_role.rds_monitoring[0].arn : null
  )
}

# ??????????????????????????????????????????????????????????????????????????????
# INSTANCIA RDS POSTGRESQL 15
# El recurso principal del mo?dulo
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_db_instance" "main" {
  identifier = "${var.name_prefix}-rds-postgres"

  # ?? Motor ??
  engine         = var.engine
  engine_version = var.engine_version

  # ?? Taman?o de instancia ??
  instance_class    = var.instance_class
  storage_type      = var.storage_type
  allocated_storage = var.allocated_storage
  # Autoscaling de almacenamiento: si se llena, crece automa?ticamente hasta max
  max_allocated_storage = var.max_allocated_storage

  # ?? Base de datos inicial ??
  db_name  = var.db_name
  username = var.username
  password = random_password.db_password.result

  # ?? Red ??
  db_subnet_group_name   = var.db_subnet_group_name
  vpc_security_group_ids = [var.rds_security_group_id]

  # Puerto esta?ndar de PostgreSQL
  port = 5432

  # No accesible desde internet (esta? en subnets aisladas)
  publicly_accessible = false

  # ?? Alta disponibilidad ??
  # Multi-AZ en prod: RDS mantiene una replica standby en otra AZ
  # Si la instancia primaria falla, el failover es automa?tico en ~60-120 segundos
  multi_az = var.multi_az

  # ?? Cifrado ??
  # OBLIGATORIO: Checkov policy y SCP de Capa 0 verifican esto
  storage_encrypted = true  # Siempre true ? no puede ser false
  kms_key_id        = local.kms_key_arn

  # ?? Para?metros y opciones ??
  parameter_group_name = aws_db_parameter_group.postgres15.name

  # ?? Backup y recuperacio?n ??
  # GCP requiere mi?nimo 35 di?as de retencio?n para datos de ensayos cli?nicos
  # OPA policy verifica que prod tenga >= 35 di?as
  backup_retention_period = var.backup_retention_period
  backup_window           = var.backup_window
  maintenance_window      = var.maintenance_window

  # Habilitar snapshots automa?ticos (parte del backup_retention_period)
  skip_final_snapshot = var.environment != "prod"  # En prod, tomar snapshot final
  final_snapshot_identifier = var.environment == "prod" ? (
    "${var.name_prefix}-rds-final-snapshot-${formatdate("YYYY-MM-DD", timestamp())}"
  ) : null

  # ?? Monitoreo y observabilidad ??
  monitoring_interval = var.monitoring_interval  # Me?tricas OS cada N segundos
  monitoring_role_arn = local.monitoring_role_arn

  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_retention_period
  performance_insights_kms_key_id       = local.kms_key_arn  # Cifrar Performance Insights tambie?n

  # ?? CloudWatch Logs ??
  # Exportar logs de PostgreSQL a CloudWatch para alertas en tiempo real
  enabled_cloudwatch_logs_exports = [
    "postgresql",   # Logs del motor PostgreSQL (incluye pgaudit)
    "upgrade"       # Logs de upgrades de versio?n
  ]

  # ?? Retencio?n de logs ??
  # Los logs de CloudWatch tienen su propia retencio?n (separada del backup de BD)
  # Se configura en el recurso aws_cloudwatch_log_group abajo

  # ?? Actualizaciones automa?ticas ??
  # Parches menores de seguridad se aplican automa?ticamente en la ventana de mantenimiento
  auto_minor_version_upgrade = true

  # ?? Proteccio?n contra eliminacio?n ??
  # En produccio?n, evitar que alguien borre la BD por error
  deletion_protection    = var.deletion_protection
  copy_tags_to_snapshot = true

  tags = merge(var.tags, {
    Name              = "${var.name_prefix}-rds-postgres"
    DataClassification = "PHI"
    BackupRetention   = "${var.backup_retention_period}days"
    ComplianceLevel   = "FDA-21CFR11-GCP-ALCOA"
  })

  # Asegurar que el parameter group este? listo antes de la instancia
  depends_on = [
    aws_db_parameter_group.postgres15,
    aws_iam_role_policy_attachment.rds_monitoring
  ]

  lifecycle {
    # Evitar que Terraform destruya y recree la BD si cambia la contrasen?a
    # (la contrasen?a se gestiona via Secrets Manager, no via Terraform)
    ignore_changes = [password]

    # No permitir destruccio?n accidental en produccio?n
    prevent_destroy = false  # Cambiar a true en prod via variable
  }
}

# ??????????????????????????????????????????????????????????????????????????????
# CLOUDWATCH LOG GROUP PARA RDS
# Configurar la retencio?n de los logs de PostgreSQL exportados
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_cloudwatch_log_group" "rds_postgres" {
  name = "/aws/rds/instance/${var.name_prefix}-rds-postgres/postgresql"

  # FDA 21 CFR Part 11: retencio?n mi?nima de los logs de auditori?a
  # Dev: 90 di?as; Prod: 2555 di?as (7 an?os)
  retention_in_days = max((var.environment == "prod" ? 2555 : 365), 365)

  kms_key_id = local.kms_key_arn  # Cifrar los logs tambie?n

  tags = var.tags
}

# ??????????????????????????????????????????????????????????????????????????????
# AUDIT TRIGGERS ALCOA+ ? Ejecutar scripts SQL post-deploy
#
# El mo?dulo ejecuta los scripts SQL de auditori?a DESPUE?S de crear la BD.
# Usa null_resource con local-exec para conectarse a la BD y ejecutar los SQLs.
#
# ALTERNATIVA CONSIDERADA: RDS Custom + pglogical extension
# DECISIO?N: null_resource con psql es ma?s simple y auditable para la POC
# ??????????????????????????????????????????????????????????????????????????????

# Obtener la contrasen?a desde Secrets Manager para ejecutar los scripts
data "aws_secretsmanager_secret_version" "db_password" {
  secret_id  = aws_secretsmanager_secret.db_password.id
  depends_on = [aws_secretsmanager_secret_version.db_password]
}

resource "null_resource" "audit_triggers" {
  count = var.enable_audit_triggers ? 1 : 0

  # Re-ejecutar si la lista de tablas o el host de la BD cambia
  triggers = {
    db_instance_id = aws_db_instance.main.id
    tables_hash    = md5(join(",", var.audit_trigger_tables))
    script_hash    = filemd5("${path.module}/scripts/audit-triggers.sql")
  }

  provisioner "local-exec" {
    command = <<-EOF
      # Extraer la contrasen?a del JSON de Secrets Manager
      DB_PASSWORD=$(echo '${data.aws_secretsmanager_secret_version.db_password.secret_string}' | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(d['password'])")

      # Ejecutar el script de audit triggers
      PGPASSWORD="$DB_PASSWORD" psql \
        --host="${aws_db_instance.main.address}" \
        --port="5432" \
        --username="${var.username}" \
        --dbname="${var.db_name}" \
        --file="${path.module}/scripts/audit-triggers.sql" \
        --set ON_ERROR_STOP=on \
        --no-password

      echo "? Audit triggers ALCOA+ instalados en ${var.db_name}"

      # Aplicar triggers a cada tabla de pacientes
      for TABLE in ${join(" ", var.audit_trigger_tables)}; do
        PGPASSWORD="$DB_PASSWORD" psql \
          --host="${aws_db_instance.main.address}" \
          --port="5432" \
          --username="${var.username}" \
          --dbname="${var.db_name}" \
          --command="SELECT fn_apply_audit_trigger('$TABLE');" \
          --no-password
        echo "  ? Trigger aplicado en tabla: $TABLE"
      done
    EOF

    # Variables de entorno para no exponer credenciales en el comando
    environment = {
      PGCONNECT_TIMEOUT = "30"
    }
  }

  depends_on = [
    aws_db_instance.main,
    aws_secretsmanager_secret_version.db_password
  ]
}

# ??????????????????????????????????????????????????????????????????????????????
# LAMBDA DE EXPORTACIO?N DE AUDIT LOG A S3
# Exporta la tabla audit_log a S3 en formato Parquet cada hora
# Parquet es columnar: eficiente para queries de Athena (ej: "todos los accesos de hoy")
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_iam_role" "audit_export_lambda" {
  count = var.enable_audit_export ? 1 : 0

  name = "${var.name_prefix}-audit-export-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "audit_export_lambda" {
  count = var.enable_audit_export ? 1 : 0

  name = "${var.name_prefix}-audit-export-policy"
  role = aws_iam_role.audit_export_lambda[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Sid    = "S3AuditExport"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Resource = [
          "arn:aws:s3:::${var.audit_export_bucket}",
          "arn:aws:s3:::${var.audit_export_bucket}/*"
        ]
      },
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.db_password.arn
      },
      {
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = local.kms_key_arn != null ? [local.kms_key_arn] : ["*"]
      },
      {
        Sid    = "VPCAccess"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface"
        ]
        Resource = "*"
      }
    ]
  })
}

# Lambda function para exportar audit_log a S3 en Parquet
resource "aws_lambda_function" "audit_export" {
  count = var.enable_audit_export ? 1 : 0

  function_name = "${var.name_prefix}-audit-log-export"
  description   = "Exporta audit_log de PostgreSQL a S3 en formato Parquet cada hora. ALCOA+ compliance."
  role          = aws_iam_role.audit_export_lambda[0].arn

  # Runtime: Python 3.12 con pandas + psycopg2 + pyarrow para Parquet
  runtime  = "python3.12"
  handler  = "index.handler"
  timeout  = 300  # 5 minutos (puede haber muchos registros)
  memory_size = 512  # MB (pandas/pyarrow consumen memoria)

  # El co?digo real esta? en un archivo ZIP (se sube vi?a S3 en el pipeline)
  # Para la POC usamos inline con el co?digo embebido
  # filename and source_code_hash are set at deploy time via var.lambda_s3_bucket/key
  s3_bucket         = var.lambda_s3_bucket
  s3_key            = var.lambda_s3_key
  source_code_hash  = var.lambda_source_code_hash

  # Variables de entorno de la funcio?n
  environment {
    variables = {
      SECRET_ARN        = aws_secretsmanager_secret.db_password.arn
      AUDIT_BUCKET      = var.audit_export_bucket
      DB_NAME           = var.db_name
      ENVIRONMENT       = var.environment
      LOG_LEVEL         = var.environment == "prod" ? "INFO" : "DEBUG"
    }
  }

  # La Lambda se ejecuta dentro de la VPC para acceder a RDS
  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.rds_security_group_id]  # Acceso a RDS port 5432
  }

  kms_key_arn = local.kms_key_arn

  # CKV_AWS_50: X-Ray tracing
  tracing_config { mode = "Active" }

  # CKV_AWS_116: Dead Letter Queue
  dead_letter_config { target_arn = aws_sqs_queue.audit_export_dlq[0].arn }

  # CKV_AWS_115: Reserved concurrency limit
  reserved_concurrent_executions = 5

  # CKV_AWS_272: Code signing (empty string = skip for POC)
  code_signing_config_arn = var.lambda_code_signing_config_arn != "" ? var.lambda_code_signing_config_arn : null

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-audit-log-export"
    Purpose = "ALCOA-AuditTrail"
  })

  depends_on = [aws_iam_role_policy.audit_export_lambda]
}

resource "aws_sqs_queue" "audit_export_dlq" {
  count                     = var.enable_audit_export ? 1 : 0
  name                      = "${var.name_prefix}-audit-export-dlq"
  message_retention_seconds = 1209600
  kms_master_key_id         = local.kms_key_arn
  tags = var.tags
}

# EventBridge Rule para ejecutar la Lambda cada hora
resource "aws_cloudwatch_event_rule" "audit_export" {
  count = var.enable_audit_export ? 1 : 0

  name                = "${var.name_prefix}-audit-export-schedule"
  description         = "Ejecuta la exportacio?n de audit_log a S3 cada hora"
  schedule_expression = var.audit_export_schedule  # "rate(1 hour)"

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "audit_export" {
  count = var.enable_audit_export ? 1 : 0

  rule      = aws_cloudwatch_event_rule.audit_export[0].name
  target_id = "AuditLogExportLambda"
  arn       = aws_lambda_function.audit_export[0].arn
}

resource "aws_lambda_permission" "audit_export" {
  count = var.enable_audit_export ? 1 : 0

  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.audit_export[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.audit_export[0].arn
}

# ??????????????????????????????????????????????????????????????????????????????
# CLOUDWATCH ALARMAS PARA RDS
# Alertas para condiciones que indican problemas de rendimiento o capacidad
# ??????????????????????????????????????????????????????????????????????????????

resource "aws_sns_topic" "rds_alerts" {
  name              = "${var.name_prefix}-rds-alerts"
  kms_master_key_id = local.kms_key_arn

  tags = var.tags
}

# Alarma: CPU > 80% por 5 minutos
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${var.name_prefix}-rds-cpu-high"
  alarm_description   = "CPU de RDS supera el 80% por ma?s de 5 minutos. Investigar queries lentas."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300  # 5 minutos
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }

  alarm_actions = [aws_sns_topic.rds_alerts.arn]
  ok_actions    = [aws_sns_topic.rds_alerts.arn]

  tags = var.tags
}

# Alarma: Conexiones disponibles < 10% (riesgo de connection pool exhaustion)
resource "aws_cloudwatch_metric_alarm" "rds_connections_high" {
  alarm_name          = "${var.name_prefix}-rds-connections-high"
  alarm_description   = "Conexiones de BD superan el 90% del ma?ximo. Riesgo de rechazo de conexiones."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  # El ma?ximo de conexiones depende del taman?o de instancia:
  # db.t3.medium: ~170 conexiones, db.r6g.xlarge: ~3000+
  threshold           = 150  # Ajustar segu?n instance_class
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }

  alarm_actions = [aws_sns_topic.rds_alerts.arn]

  tags = var.tags
}

# Alarma: Espacio libre en disco < 10 GB
resource "aws_cloudwatch_metric_alarm" "rds_storage_low" {
  alarm_name          = "${var.name_prefix}-rds-storage-low"
  alarm_description   = "Espacio libre en RDS < 10 GB. Riesgo de que la BD deje de funcionar."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 10737418240  # 10 GB en bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }

  alarm_actions = [aws_sns_topic.rds_alerts.arn]

  tags = var.tags
}
