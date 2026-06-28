# ??????????????????????????????????????????????????????????????????????????????
# environments/staging/compute/terragrunt.hcl
# Staging: 2 tasks (simula HA de prod), instancias medianas
# ??????????????????????????????????????????????????????????????????????????????

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "../../../modules//compute"
}

dependency "network" {
  config_path = "../network"
  mock_outputs_merge_strategy_with_state  = "shallow"
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init", "apply"]
  mock_outputs = {
    vpc_id                = "vpc-00000000000000000"
    public_subnet_ids     = ["subnet-1", "subnet-2"]
    private_subnet_ids    = ["subnet-3", "subnet-4"]
    alb_security_group_id = "sg-1"
    ecs_security_group_id = "sg-2"
  }
}

dependency "database" {
  config_path = "../database"
  mock_outputs_merge_strategy_with_state  = "shallow"
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init", "apply"]
  mock_outputs = {
    secret_arn  = "arn:aws:secretsmanager:us-east-1:333333333333:secret:brainmart-staging/database/master-password-XXXXXX"
    kms_key_arn = "arn:aws:kms:us-east-1:333333333333:key/00000000-0000-0000-0000-000000000000"
  }
}

inputs = {
  environment           = "staging"
  name_prefix           = "brainmart-staging"
  service_name          = "patient-service"
  vpc_id                = dependency.network.outputs.vpc_id
  public_subnet_ids     = dependency.network.outputs.public_subnet_ids
  private_subnet_ids    = dependency.network.outputs.private_subnet_ids
  alb_security_group_id = dependency.network.outputs.alb_security_group_id
  ecs_security_group_id = dependency.network.outputs.ecs_security_group_id
  kms_key_arn           = dependency.database.outputs.kms_key_arn
  db_secret_arn         = dependency.database.outputs.secret_arn

  jwt_secret_arn      = "arn:aws:secretsmanager:us-east-1:333333333333:secret:brainmart-staging/jwt/signing-key"
  acm_certificate_arn = "arn:aws:acm:us-east-1:333333333333:certificate/STAGING-CERT-ARN"
  alb_logs_bucket     = "brainmart-staging-alb-logs"
  sns_alerts_topic_arn = "arn:aws:sns:us-east-1:333333333333:brainmart-staging-alerts"

  ecr_image_uri = "567890123456.dkr.ecr.us-east-1.amazonaws.com/brainmart/patient-service"
  image_tag     = "latest"

  task_cpu    = 512
  task_memory = 1024

  # Staging simula prod: 2 tasks mi?nimo para probar HA
  desired_count = 2
  min_capacity  = 2
  max_capacity  = 6

  enable_service_discovery = true

  tags = {
    Module           = "compute"
    CriticalityLevel = "medium"
  }
}
