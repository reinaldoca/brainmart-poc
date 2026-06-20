variable "environment"           { type = string }
variable "name_prefix"           { type = string }
variable "service_name" {
  type    = string
  default = "patient-service"
}
variable "vpc_id"                { type = string }
variable "public_subnet_ids"     { type = list(string) }
variable "private_subnet_ids"    { type = list(string) }
variable "alb_security_group_id" { type = string }
variable "ecs_security_group_id" { type = string }
variable "ecr_image_uri"         { type = string }
variable "image_tag" {
  type    = string
  default = "latest"
}
variable "kms_key_arn"           { type = string }
variable "db_secret_arn"         { type = string }
variable "jwt_secret_arn"        { type = string }
variable "acm_certificate_arn"   { type = string }
variable "alb_logs_bucket"       { type = string }
variable "sns_alerts_topic_arn"  { type = string }
variable "alb_deletion_protection" {
  description = "Enable deletion protection on the ALB. Checkov CKV_AWS_150 requires true. Override to false only in dev."
  type        = bool
  default     = true
}

variable "waf_web_acl_arn" {
  description = "ARN of WAF WebACL to associate with the ALB (CKV2_AWS_28)"
  type        = string
  default     = ""
}

variable "task_cpu" {
  type        = number
  default     = 512
  description = "CPU units para la tarea ECS. 512 = 0.5 vCPU"
}

variable "task_memory" {
  type        = number
  default     = 1024
  description = "MB de memoria para la tarea ECS"
}

variable "desired_count" {
  type        = number
  description = "Nu?mero deseado de tareas. OPA verifica >= 2 en prod"
}

variable "min_capacity" {
  type    = number
  default = 1
}

variable "max_capacity" {
  type    = number
  default = 10
}

variable "enable_service_discovery" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
