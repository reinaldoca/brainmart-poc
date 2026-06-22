# infrastructure/policy-as-code/opa/policies/required_tags.rego
# OPA POLICY: All resources must have mandatory compliance tags
#
# REQUIRED TAGS: Environment, Project, Owner, ComplianceLevel
# RATIONALE: FDA 21 CFR Part 11 + GCP ICH E6(R2) + GDPR traceability

package brainmart.tags

import rego.v1

# Mandatory tags for all tracked resources
required_tags := {"Environment", "Project", "Owner", "ComplianceLevel"}

# Resource types that must carry compliance tags
tagged_resource_types := {
    "aws_instance", "aws_db_instance", "aws_rds_cluster",
    "aws_s3_bucket", "aws_ecs_cluster", "aws_ecs_service",
    "aws_lambda_function", "aws_elasticache_cluster",
    "aws_cloudfront_distribution", "aws_wafv2_web_acl"
}

# ---------------------------------------------------------------------------
# DENY rules
# ---------------------------------------------------------------------------

# Resources missing mandatory tags
deny contains msg if {
    some resource in input.resource_changes
    resource.type in tagged_resource_types
    resource.change.actions[_] in {"create", "update"}
    config := resource.change.after
    missing := missing_tags(config)
    count(missing) > 0
    msg := sprintf(
        "[Tags Compliance] Resource '%s' (type: %s) is missing mandatory tags: %v. Required: %v. Current: %v. Tags are mandatory for FDA/GCP/GDPR traceability.",
        [resource.address, resource.type, missing, required_tags, object.keys(object.get(config, "tags", {}))]
    )
}

# Environment tag must have a valid value
deny contains msg if {
    some resource in input.resource_changes
    resource.type in tagged_resource_types
    resource.change.actions[_] in {"create", "update"}
    config := resource.change.after
    tags := object.get(config, "tags", {})
    env_value := object.get(tags, "Environment", "")
    env_value != ""
    not env_value in {"dev", "staging", "prod", "shared-services", "production"}
    msg := sprintf(
        "[Tags Validation] Resource '%s' has invalid Environment tag value '%s'. Allowed: dev, staging, prod, shared-services.",
        [resource.address, env_value]
    )
}

# Project tag must be "brainmart"
deny contains msg if {
    some resource in input.resource_changes
    resource.type in tagged_resource_types
    resource.change.actions[_] in {"create", "update"}
    config := resource.change.after
    tags := object.get(config, "tags", {})
    project_value := object.get(tags, "Project", "")
    project_value != ""
    project_value != "brainmart"
    msg := sprintf(
        "[Tags Validation] Resource '%s' has Project='%s'. Must be 'brainmart'. Check root terragrunt.hcl input.",
        [resource.address, project_value]
    )
}

# ComplianceLevel tag on data resources must reference FDA
deny contains msg if {
    some resource in input.resource_changes
    resource.type in {"aws_db_instance", "aws_rds_cluster", "aws_s3_bucket"}
    resource.change.actions[_] in {"create", "update"}
    config := resource.change.after
    tags := object.get(config, "tags", {})
    compliance_level := object.get(tags, "ComplianceLevel", "")
    compliance_level != ""
    not contains(compliance_level, "FDA")
    msg := sprintf(
        "[Tags ComplianceLevel] Data resource '%s' (type: %s) has ComplianceLevel='%s' which does not reference FDA. PHI data resources must include FDA (e.g. 'FDA-21CFR11-GCP-ALCOA-GDPR').",
        [resource.address, resource.type, compliance_level]
    )
}

# ---------------------------------------------------------------------------
# WARN rules
# ---------------------------------------------------------------------------

warn contains msg if {
    some resource in input.resource_changes
    resource.type in {"aws_db_instance", "aws_ecs_service", "aws_lambda_function"}
    resource.change.actions[_] in {"create", "update"}
    config := resource.change.after
    tags := object.get(config, "tags", {})
    not "CostCenter" in object.keys(tags)
    msg := sprintf(
        "[Tags CostCenter] Resource '%s' has no CostCenter tag. Recommended for clinical trial cost allocation (e.g. CostCenter='trial-NCT-2024-001').",
        [resource.address]
    )
}

# ---------------------------------------------------------------------------
# HELPER functions
# ---------------------------------------------------------------------------

missing_tags(config) := missing if {
    actual_tags := object.get(config, "tags", {})
    existing_tag_keys := {key | some key, _ in actual_tags}
    missing := required_tags - existing_tag_keys
}

# Data sources do not require tags
allow if {
    input.resource_changes[_].mode == "data"
}