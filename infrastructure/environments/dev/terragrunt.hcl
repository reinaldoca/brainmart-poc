# environments/dev/terragrunt.hcl
#
# PURPOSE: Environment-level locals for DEV.
# This file defines ONLY locals - it does NOT include the root config.
# Child modules (network/, database/, etc.) include the root directly
# via find_in_parent_folders("root.hcl") which traverses up to infrastructure/terragrunt.hcl.
#
# TERRAGRUNT INCLUDE CHAIN (single level, as required):
#   environments/dev/network/terragrunt.hcl
#     -> includes infrastructure/terragrunt.hcl  (root, via find_in_parent_folders("root.hcl"))
#
# ANTI-PATTERN AVOIDED: If this file also included the root, child modules would
# trigger a double-include error ("only one level of includes is allowed").

locals {
  # Read the environment-specific account.hcl (environments/dev/account.hcl)
  # That file has: locals { account_id = "...", account_name = "dev" }
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  region_vars  = read_terragrunt_config(find_in_parent_folders("region.hcl"))

  environment = "dev"
  aws_region  = local.region_vars.locals.aws_region

  # The local account.hcl has account_id directly (not nested under "accounts")
  account_id  = local.account_vars.locals.account_id
}
# This file provides locals only - it is not a deployable unit.
skip = true
