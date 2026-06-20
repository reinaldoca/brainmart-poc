# ??????????????????????????????????????????????????????????????????????????????
# environments/prod/compute/terragrunt.hcl
# PROD: desired_count=2 (OPA verifica HA), db.r6g instancias
# ??????????????????????????????????????????????????????????????????????????????

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "../../../../modules//compute"
}

dependency "network" {
  config_path = "../network"
  mock_outputs = {
    vpc_id                = "vpc-00000000000000000"
    public_subnet_ids     = ["subnet-1", "subnet-2", "subnet-3"]
    private_subnet_ids    = ["subnet-4", "subnet-5", "subnet-6"]
    alb_security_group_id = "sg-00000000000000001"
    ecs_security_group_id = "sg-00000000000000002"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "database" {
  config_path = "../database"
  mock_outputs = {
    secret_arn  = "arn:aws:secretsmanager:us-east-1:444444444444:secret:brainmart-prod/database/master-password-XXXXXX"
    kms_key_arn = "arn:aws:kms:us-east-1:444444444444:key/00000000-0000-0000-0000-000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  environment           = "prod"
  name_prefix           = "brainmart-prod"
  service_name          = "patient-service"
  vpc_id                = dependency.network.outputs.vpc_id
  public_subnet_ids     = dependency.network.outputs.public_subnet_ids
  private_subnet_ids    = dependency.network.outputs.private_subnet_ids
  alb_security_group_id = dependency.network.outputs.alb_security_group_id
  ecs_security_group_id = dependency.network.outputs.ecs_security_group_id
  kms_key_arn           = dependency.database.outputs.kms_key_arn
  db_secret_arn         = dependency.database.outputs.secret_arn

  jwt_secret_arn      = "arn:aws:secretsmanager:us-east-1:444444444444:secret:brainmart-prod/jwt/signing-key"
  acm_certificate_arn = "arn:aws:acm:us-east-1:444444444444:certificate/PROD-CERT-ARN"
  alb_logs_bucket     = "brainmart-prod-alb-logs"
  sns_alerts_topic_arn = "arn:aws:sns:us-east-1:444444444444:brainmart-prod-alerts"

  ecr_image_uri = "567890123456.dkr.ecr.us-east-1.amazonaws.com/brainmart/patient-service"
  image_tag     = "latest"

  # PROD: instancias ma?s grandes
  task_cpu    = 1024  # 1 vCPU
  task_memory = 2048  # 2 GB

  # OPA policy (rds_multi_az.rego): desired_count >= 2 en produccio?n
  desired_count = 2
  min_capacity  = 2   # Nunca bajar de 2 tasks en prod
  max_capacity  = 20

  enable_service_discovery = true

  tags = {
    Module           = "compute"
    CriticalityLevel = "critical"
  }
}
