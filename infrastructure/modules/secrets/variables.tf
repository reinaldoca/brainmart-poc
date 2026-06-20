variable "environment"          { type = string }
variable "name_prefix"          { type = string }
variable "third_party_api_keys" { type = map(map(string)); default = {} }
variable "tags"                 { type = map(string); default = {} }
