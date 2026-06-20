variable "environment"                  { type = string }
variable "name_prefix"                  { type = string }
variable "kms_key_arn"                  { type = string }
variable "domain_names" {
  type    = list(string)
  default = []
}
variable "acm_certificate_arn"          { type = string }
variable "audit_export_lambda_role_arn" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}
