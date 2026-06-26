# ??????????????????????????????????????????????????????????????????????????????
# environments/staging/database/terragrunt.hcl
# Staging: db.t3.large, Multi-AZ habilitado, backup 14 di?as
# ??????????????????????????????????????????????????????????????????????????????

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "../../../modules//database"
}

dependency "network" {
  config_path = "../network"
  mock_outputs = {
    vpc_id              = "vpc-00000000000000000"
    isolated_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000002"]
    private_subnet_ids  = ["subnet-00000000000000003", "subnet-00000000000000004"]
    rds_security_group_id = "sg-00000000000000001"
    db_subnet_group_name  = "brainmart-staging-db-subnet-group"
    vpc_cidr_block        = "10.20.0.0/16"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init", "apply"]
}

inputs = {
  environment          = "staging"
  name_prefix          = "brainmart-staging"
  vpc_id               = dependency.network.outputs.vpc_id
  subnet_ids           = dependency.network.outputs.private_subnet_ids
  db_subnet_group_name = dependency.network.outputs.db_subnet_group_name
  rds_security_group_id = dependency.network.outputs.rds_security_group_id
  allowed_cidr_blocks  = [dependency.network.outputs.vpc_cidr_block]

  instance_class        = "db.t3.large"   # Ma?s grande que dev, menor que prod
  allocated_storage     = 50
  max_allocated_storage = 200

  # STAGING simula produccio?n: Multi-AZ habilitado
  multi_az = true

  db_name  = "brainmart_staging"
  username = "brainmart_admin"

  # Staging: 14 di?as (ma?s que dev, menos que el requisito de 35 en prod)
  backup_retention_period = 14
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  storage_encrypted              = true
  performance_insights_enabled   = true
  performance_insights_retention_period = 7
  monitoring_interval            = 60
  enable_audit_triggers          = true
  enable_audit_export            = true
  audit_export_bucket            = "brainmart-staging-audit-logs"
  deletion_protection            = false

  audit_trigger_tables = [
    "patients", "clinical_trials", "trial_participants",
    "adverse_events", "dosing_records", "consent_forms"
  ]

  tags = {
    Module             = "database"
    DataClassification = "PHI"
    CriticalityLevel   = "medium"
  }
}
