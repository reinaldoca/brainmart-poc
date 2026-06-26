# ??????????????????????????????????????????????????????????????????????????????
# environments/prod/database/terragrunt.hcl
#
# PRODUCCIO?N: db.r6g.xlarge, Multi-AZ, backup 35 di?as, deletion_protection=true
# OPA policy verifica multi_az=true y backup>=35 di?as en produccio?n
# ??????????????????????????????????????????????????????????????????????????????

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "../../../../modules//database"
}

dependency "network" {
  config_path = "../network"
  mock_outputs = {
    vpc_id                = "vpc-00000000000000000"
    isolated_subnet_ids   = ["subnet-00000000000000001", "subnet-00000000000000002", "subnet-00000000000000003"]
    private_subnet_ids    = ["subnet-00000000000000004", "subnet-00000000000000005", "subnet-00000000000000006"]
    rds_security_group_id = "sg-00000000000000001"
    db_subnet_group_name  = "brainmart-prod-db-subnet-group"
    vpc_cidr_block        = "10.30.0.0/16"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init", "apply"]
}

inputs = {
  environment           = "prod"
  name_prefix           = "brainmart-prod"
  vpc_id                = dependency.network.outputs.vpc_id
  subnet_ids            = dependency.network.outputs.private_subnet_ids
  db_subnet_group_name  = dependency.network.outputs.db_subnet_group_name
  rds_security_group_id = dependency.network.outputs.rds_security_group_id
  allowed_cidr_blocks   = [dependency.network.outputs.vpc_cidr_block]

  # PROD: instancia de memoria optimizada para PostgreSQL con cargas OLTP
  instance_class        = "db.r6g.xlarge"
  allocated_storage     = 100
  max_allocated_storage = 1000  # 1 TB ma?ximo con autoscaling

  # ??? REQUISITOS PROD ? verificados por OPA ???
  multi_az = true  # OPA: rds_multi_az.rego verifica esto en prod

  db_name  = "brainmart_prod"
  username = "brainmart_admin"

  # GCP ICH E6(R2): mi?nimo 35 di?as de retencio?n
  # OPA: rds_multi_az.rego verifica backup_retention_period >= 35
  backup_retention_period = 35
  backup_window           = "02:00-03:00"   # UTC: 22:00-23:00 EST (bajo tra?fico)
  maintenance_window      = "sun:03:00-sun:04:00"

  storage_encrypted     = true  # Siempre true ? SCP lo enforce tambie?n
  deletion_protection   = true  # PRODUCCIO?N: no se puede borrar sin deshabilitarlo

  performance_insights_enabled          = true
  performance_insights_retention_period = 731  # 2 an?os en prod
  monitoring_interval                   = 15   # Cada 15 segundos en prod

  enable_audit_triggers = true
  enable_audit_export   = true
  audit_export_bucket   = "brainmart-prod-audit-logs"
  audit_export_schedule = "rate(1 hour)"

  audit_trigger_tables = [
    "patients", "clinical_trials", "trial_participants",
    "adverse_events", "dosing_records", "consent_forms",
    "lab_results", "vital_signs", "medications", "visit_records"
  ]

  tags = {
    Module             = "database"
    DataClassification = "PHI"
    CriticalityLevel   = "critical"
    BackupFrequency    = "continuous-pitr"
    ComplianceLevel    = "FDA-21CFR11-GCP-ALCOA-GDPR"
  }
}
