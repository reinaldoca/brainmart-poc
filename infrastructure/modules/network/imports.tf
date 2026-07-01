# ══════════════════════════════════════════════════════════════════════════════
# infrastructure/modules/network/imports.tf
#
# PURPOSE: Auto-import orphaned Security Groups that exist in AWS but are
#          missing from Terraform state. This happens when a previous apply
#          was interrupted by a broken-pipe (CI runner OOM / network drop)
#          AFTER the SG was created in AWS but BEFORE state was saved.
#
# MECHANISM:
#   data "aws_security_groups" (plural) — returns an EMPTY LIST without
#   failing when no SGs match. This makes the import blocks safe for:
#     - Fresh deploy:    SG doesn't exist → ids=[] → for_each=∅ → no import
#     - Broken-pipe run: SG exists in AWS → ids=["sg-xxx"] → import runs
#     - Healthy run:     SG already in state → Terraform skips the import block
#
# Requires Terraform ≥ 1.7 (for_each on import blocks).
# ══════════════════════════════════════════════════════════════════════════════

# ── ALB Security Group ────────────────────────────────────────────────────────
data "aws_security_groups" "orphaned_alb" {
  filter {
    name   = "group-name"
    values = ["${var.name_prefix}-alb-sg"]
  }
  filter {
    name   = "vpc-id"
    values = [aws_vpc.main.id]
  }
}

import {
  for_each = length(data.aws_security_groups.orphaned_alb.ids) > 0 ? toset([data.aws_security_groups.orphaned_alb.ids[0]]) : toset([])
  to       = aws_security_group.alb
  id       = each.value
}

# ── ECS Security Group ────────────────────────────────────────────────────────
data "aws_security_groups" "orphaned_ecs" {
  filter {
    name   = "group-name"
    values = ["${var.name_prefix}-ecs-sg"]
  }
  filter {
    name   = "vpc-id"
    values = [aws_vpc.main.id]
  }
}

import {
  for_each = length(data.aws_security_groups.orphaned_ecs.ids) > 0 ? toset([data.aws_security_groups.orphaned_ecs.ids[0]]) : toset([])
  to       = aws_security_group.ecs
  id       = each.value
}

# ── RDS Security Group ────────────────────────────────────────────────────────
data "aws_security_groups" "orphaned_rds" {
  filter {
    name   = "group-name"
    values = ["${var.name_prefix}-rds-sg"]
  }
  filter {
    name   = "vpc-id"
    values = [aws_vpc.main.id]
  }
}

import {
  for_each = length(data.aws_security_groups.orphaned_rds.ids) > 0 ? toset([data.aws_security_groups.orphaned_rds.ids[0]]) : toset([])
  to       = aws_security_group.rds
  id       = each.value
}

# ── VPC Endpoints Security Group ──────────────────────────────────────────────
data "aws_security_groups" "orphaned_vpc_endpoints" {
  filter {
    name   = "group-name"
    values = ["${var.name_prefix}-vpc-endpoints-sg"]
  }
  filter {
    name   = "vpc-id"
    values = [aws_vpc.main.id]
  }
}

import {
  for_each = length(data.aws_security_groups.orphaned_vpc_endpoints.ids) > 0 ? toset([data.aws_security_groups.orphaned_vpc_endpoints.ids[0]]) : toset([])
  to       = aws_security_group.vpc_endpoints
  id       = each.value
}
