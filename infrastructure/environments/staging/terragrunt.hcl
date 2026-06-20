# environments/staging/terragrunt.hcl
# ONLY locals - no include block (child modules include the root directly).

locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  region_vars  = read_terragrunt_config(find_in_parent_folders("region.hcl"))

  environment = "staging"
  aws_region  = local.region_vars.locals.aws_region
  account_id  = local.account_vars.locals.account_id
}
# This file provides locals only - it is not a deployable unit.
skip = true
