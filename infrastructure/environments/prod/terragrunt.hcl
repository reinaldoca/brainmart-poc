# environments/prod/terragrunt.hcl
#
# This directory is NOT a deployable unit - it contains only environment
# configuration (account.hcl, region.hcl) consumed by child units.
#
# The "exclude" block (Terragrunt v1.0+) prevents this directory from
# being discovered and executed by "run-all" commands.
# Deployable units are the subdirectories: network/, database/, compute/, storage/

exclude {
  if      = true
  actions = ["all"]
}