# region.hcl especi?fico para el ambiente DEV
# Sobreescribe los valores del region.hcl rai?z
locals {
  aws_region = "us-east-1"
  dr_region  = null  # DEV no tiene DR
}
