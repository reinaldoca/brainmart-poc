# ??????????????????????????????????????????????????????????????????????????????
# infrastructure/environments/dev/database/terragrunt.hcl
#
# PROPO?SITO: Despliega RDS PostgreSQL 15 para el ambiente DEV.
#
# DEPENDENCIAS: network (necesita VPC ID y subnet IDs de subnets aisladas)
# OUTPUTS USADOS POR: compute (connection string), secrets (credenciales)
#
# CONFIGURACIO?N DEV:
#   - Instancia: db.t3.medium (desarrollo, bajo costo)
#   - Sin Multi-AZ (no necesario en dev, ahorro de costos)
#   - Backup: 7 di?as (OPA policy require 35 en prod, dev es flexible)
#   - Performance Insights: habilitado (para debugging de queries lentas)
#   - Audit triggers: habilitados (necesario para demostrar ALCOA+)
#
# NOTA SOBRE CHECKOV:
#   La custom policy check_rds_backup_retention.py verifica >= 35 di?as en PROD.
#   En DEV se permite < 35 di?as pero se registra en el dashboard de compliance.
# ??????????????????????????????????????????????????????????????????????????????

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

# ?? Mo?dulo de base de datos ??
terraform {
  source = "../../../modules//database"
}

# ?? Dependencia de red: necesitamos VPC ID y subnet IDs ??
# Terragrunt espera a que el mo?dulo de red termine antes de planificar este
# y automa?ticamente pasa los outputs como variables de entrada
dependency "network" {
  config_path = "../network"

  # Mock outputs para poder hacer plan sin que network este? desplegado
  # U?til en CI/CD para validar la sintaxis antes del primer deploy
  mock_outputs = {
    vpc_id              = "vpc-00000000000000000"
    isolated_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000002"]
    private_subnet_ids  = ["subnet-00000000000000003", "subnet-00000000000000004"]
    vpc_cidr_block      = "10.10.0.0/16"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
}

inputs = {
  # ?? Identidad ??
  environment = "dev"
  name_prefix = "brainmart-dev"

  # ?? Red: valores de la dependencia de network ??
  vpc_id             = dependency.network.outputs.vpc_id
  subnet_ids         = dependency.network.outputs.isolated_subnet_ids
  allowed_cidr_blocks = [dependency.network.outputs.vpc_cidr_block]

  # ?? Motor de base de datos ??
  engine         = "postgres"
  engine_version = "15.6"

  # ?? Configuracio?n de la instancia DEV ??
  instance_class = "db.t3.medium"  # Pequen?a para dev (prod: db.r6g.xlarge)
  storage_type   = "gp3"
  allocated_storage     = 20   # GB inicial
  max_allocated_storage = 100  # GB ma?ximo (autoscaling de almacenamiento)

  # ?? Multi-AZ: deshabilitado en dev para ahorrar costos ??
  # OPA policy verifica que este? habilitado en PRODUCCIO?N
  multi_az = false

  # ?? Base de datos y usuarios ??
  db_name  = "brainmart_dev"
  username = "brainmart_admin"
  # La contrasen?a se genera automa?ticamente y se guarda en Secrets Manager
  # NUNCA hardcodear contrasen?as en archivos de configuracio?n

  # ?? Backup ??
  # DEV: 7 di?as (mi?nimo). PROD: 35 di?as (GCP requirement)
  # OPA policy verifica que prod tenga >= 35 di?as
  backup_retention_period = 7
  backup_window           = "03:00-04:00"  # UTC, fuera de horario laboral
  maintenance_window      = "sun:04:00-sun:05:00"

  # ?? PITR (Point In Time Recovery) ??
  # Habilitado incluso en dev para poder demostrar la funcionalidad
  enable_pitr = true

  # ?? Cifrado en reposo con KMS CMK ??
  # OBLIGATORIO: Checkov policy y SCP de Capa 0 verifican esto
  # Se usa una CMK especi?fica para la base de datos (no la default de AWS)
  storage_encrypted = true
  kms_key_id        = ""  # Vaci?o = crear nueva CMK para esta BD (ver mo?dulo)

  # ?? Performance Insights ??
  # Habilitado en dev para debugging de queries lentas de la aplicacio?n
  performance_insights_enabled          = true
  performance_insights_retention_period = 7  # di?as (dev), 731 en prod

  # ?? Enhanced Monitoring ??
  # Me?tricas del OS cada 60 segundos
  monitoring_interval = 60
  monitoring_role_arn = ""  # Vaci?o = crear nuevo rol de monitoreo

  # ?? Para?metros de PostgreSQL para ALCOA+ ??
  # Habilitamos los para?metros necesarios para los triggers de auditori?a
  db_parameters = [
    # Habilitar log de todos los statements para auditori?a
    {
      name  = "log_statement"
      value = "all"
    },
    # Registrar la duracio?n de los statements
    {
      name  = "log_duration"
      value = "on"
    },
    # Nivel de WAL para replicacio?n lo?gica cross-region (DR)
    {
      name         = "wal_level"
      value        = "logical"
      apply_method = "pending-reboot"
    },
    # Nu?mero ma?ximo de replication slots (necesario para pglogical)
    {
      name         = "max_replication_slots"
      value        = "5"
      apply_method = "pending-reboot"
    },
    # Worker processes para replicacio?n lo?gica
    {
      name         = "max_worker_processes"
      value        = "8"
      apply_method = "pending-reboot"
    }
  ]

  # ?? Audit Triggers ALCOA+ ??
  # El mo?dulo ejecuta el script SQL de triggers despue?s de crear la BD
  # ALCOA+: cada INSERT/UPDATE/DELETE en tablas de pacientes genera un registro
  enable_audit_triggers = true
  audit_trigger_tables = [
    "patients",
    "clinical_trials",
    "trial_participants",
    "adverse_events",
    "dosing_records",
    "consent_forms"
  ]

  # ?? Exportacio?n de audit log a S3 ??
  # Cada hora se exporta la tabla audit_log a S3 en formato Parquet
  # para ser consultada con Athena desde el dashboard de auditori?a
  enable_audit_export     = true
  audit_export_bucket     = "brainmart-dev-audit-logs"
  audit_export_schedule   = "rate(1 hour)"

  # ?? Deletion protection ??
  deletion_protection = false  # false en dev para poder destruir, true en prod

  # ?? Tags adicionales ??
  tags = {
    Module           = "database"
    DataClassification = "PHI"  # Protected Health Information
    CriticalityLevel = "low"
    BackupFrequency  = "daily"
    ComplianceLevel  = "FDA-21CFR11-GCP-ALCOA"
  }
}
