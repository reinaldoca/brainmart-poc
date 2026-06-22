# infrastructure/policy-as-code/opa/policies/rds_multi_az.rego
# OPA POLICY: Validate RDS configuration for clinical trial compliance
#
# REGULATORY CONTEXT:
#   - GCP ICH E6(R2) s5.5.3: Systems must have service continuity
#   - FDA 21 CFR Part 11 s11.10(c): PHI data encryption mandatory
#
# LOCAL USAGE:
#   conftest test tfplan.json --policy . --namespace brainmart.rds

package brainmart.rds

import rego.v1

# ---------------------------------------------------------------------------
# DENY rules - any match blocks the pipeline
# ---------------------------------------------------------------------------

# Production RDS MUST have multi_az = true
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_db_instance"
    action_creates_or_updates(resource.change.actions)
    config := resource.change.after
    is_production_resource(config)
    not config.multi_az
    msg := sprintf(
        "[RDS Multi-AZ PROD] Instance '%s' in production must have multi_az=true. Requirement: GCP ICH E6(R2) s5.5.3 + FDA 21 CFR Part 11. Environment: '%s'. Class: '%s'.",
        [resource.address, config.tags.Environment, config.instance_class]
    )
}

# Production RDS MUST have backup_retention_period >= 35 days (GCP ICH E6 R2)
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_db_instance"
    action_creates_or_updates(resource.change.actions)
    config := resource.change.after
    is_production_resource(config)
    config.backup_retention_period < 35
    msg := sprintf(
        "[RDS Backup PROD] Instance '%s' has backup=%d days. Minimum 35 days required by GCP ICH E6(R2) for clinical trial data retention.",
        [resource.address, config.backup_retention_period]
    )
}

# ALL environments: RDS MUST have storage_encrypted = true
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_db_instance"
    action_creates_or_updates(resource.change.actions)
    config := resource.change.after
    not config.storage_encrypted
    msg := sprintf(
        "[RDS Encryption] Instance '%s' does not have storage_encrypted=true. MANDATORY in all environments per FDA 21 CFR Part 11 s11.10(c) PHI encryption.",
        [resource.address]
    )
}

# Production RDS MUST have deletion_protection = true
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_db_instance"
    action_creates_or_updates(resource.change.actions)
    config := resource.change.after
    is_production_resource(config)
    not config.deletion_protection
    msg := sprintf(
        "[RDS Deletion Protection] Instance '%s' in production must have deletion_protection=true per GCP ICH E6(R2) clinical trial data preservation.",
        [resource.address]
    )
}

# ---------------------------------------------------------------------------
# WARN rules - reported but do NOT block the pipeline
# ---------------------------------------------------------------------------

warn contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_db_instance"
    action_creates_or_updates(resource.change.actions)
    config := resource.change.after
    config.tags.Environment in {"staging", "uat"}
    config.backup_retention_period < 14
    msg := sprintf(
        "[RDS Backup STAGING] Instance '%s' has only %d days of backup. Recommended >=14 days for staging.",
        [resource.address, config.backup_retention_period]
    )
}

# ---------------------------------------------------------------------------
# HELPER functions
# ---------------------------------------------------------------------------

action_creates_or_updates(actions) if {
    actions[_] in {"create", "update"}
}

is_production_resource(config) if { config.tags.Environment == "prod" }
is_production_resource(config) if { config.tags.Environment == "production" }
is_production_resource(config) if { contains(config.identifier, "-prod-") }