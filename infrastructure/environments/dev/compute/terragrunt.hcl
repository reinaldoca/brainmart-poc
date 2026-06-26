# ??????????????????????????????????????????????????????????????????????????????
# infrastructure/environments/dev/compute/terragrunt.hcl
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
  mock_outputs = {
    vpc_id                  = "vpc-00000000000000000"
    public_subnet_ids       = ["subnet-00000000000000001", "subnet-00000000000000002"]
    private_subnet_ids      = ["subnet-00000000000000003", "subnet-00000000000000004"]
    alb_security_group_id   = "sg-00000000000000001"
    ecs_security_group_id   = "sg-00000000000000002"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init", "apply"]
}

dependency "database" {
  config_path = "../database"
  mock_outputs = {
    secret_arn  = "arn:aws:secretsmanager:us-east-1:222222222222:secret:brainmart-dev/database/master-password-XXXXXX"
    kms_key_arn = "arn:aws:kms:us-east-1:222222222222:key/00000000-0000-0000-0000-000000000000"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init", "apply"]
}

inputs = {
  environment            = "dev"
  name_prefix            = "brainmart-dev"
  service_name           = "patient-service"
  vpc_id                 = dependency.network.outputs.vpc_id
  public_subnet_ids      = dependency.network.outputs.public_subnet_ids
  private_subnet_ids     = dependency.network.outputs.private_subnet_ids
  alb_security_group_id  = dependency.network.outputs.alb_security_group_id
  ecs_security_group_id  = dependency.network.outputs.ecs_security_group_id
  kms_key_arn            = dependency.database.outputs.kms_key_arn
  db_secret_arn          = dependency.database.outputs.secret_arn
  jwt_secret_arn         = "arn:aws:secretsmanager:us-east-1:222222222222:secret:brainmart-dev/jwt/signing-key"
  acm_certificate_arn    = "arn:aws:acm:us-east-1:222222222222:certificate/00000000-0000-0000-0000-000000000000"
  alb_logs_bucket        = "brainmart-dev-alb-logs"
  sns_alerts_topic_arn   = "arn:aws:sns:us-east-1:222222222222:brainmart-dev-alerts"

  # ECR image ? en dev se usa la imagen ma?s reciente del branch actual
  ecr_image_uri = "567890123456.dkr.ecr.us-east-1.amazonaws.com/brainmart/patient-service"
  image_tag     = "latest"

  # Taman?o de la tarea ? ma?s pequen?o en dev
  task_cpu    = 256   # 0.25 vCPU
  task_memory = 512   # 512 MB

  # Nu?mero de tasks: en dev con 1 es suficiente
  # OPA policy: prod requiere >= 2
  desired_count = 1
  min_capacity  = 1
  max_capacity  = 3

  enable_service_discovery = true

  tags = {
    Module           = "compute"
    CriticalityLevel = "low"
  }
}
