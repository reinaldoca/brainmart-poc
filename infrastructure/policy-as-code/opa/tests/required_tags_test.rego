# ──────────────────────────────────────────────────────────────────────────────
# infrastructure/policy-as-code/opa/tests/required_tags_test.rego
# Tests unitarios para la política de tags obligatorios
# ──────────────────────────────────────────────────────────────────────────────

package brainmart.tags_test

import data.brainmart.tags

# ── Test: recurso SIN todos los tags DEBE fallar ──────────────────────────────
test_resource_without_required_tags_fails if {
  result := tags.deny with input as {
    "resource_changes": [{
      "address": "aws_db_instance.main",
      "type":    "aws_db_instance",
      "change":  {
        "actions": ["create"],
        "after": {
          "tags": {
            "Environment": "prod"
            # Faltan: Project, Owner, ComplianceLevel
          }
        }
      }
    }]
  }
  count(result) > 0
}

# ── Test: recurso CON todos los tags DEBE pasar ───────────────────────────────
test_resource_with_all_tags_passes if {
  result := tags.deny with input as {
    "resource_changes": [{
      "address": "aws_db_instance.main",
      "type":    "aws_db_instance",
      "change":  {
        "actions": ["create"],
        "after": {
          "tags": {
            "Environment":    "prod",
            "Project":        "brainmart",
            "Owner":          "devsecops-team@brainmart.health",
            "ComplianceLevel": "FDA-21CFR11-GCP-ALCOA-GDPR"
          }
        }
      }
    }]
  }
  count(result) == 0
}

# ── Test: Environment con valor inválido DEBE fallar ──────────────────────────
test_invalid_environment_value_fails if {
  result := tags.deny with input as {
    "resource_changes": [{
      "address": "aws_s3_bucket.main",
      "type":    "aws_s3_bucket",
      "change":  {
        "actions": ["create"],
        "after": {
          "tags": {
            "Environment":    "produccion",  # ← Inválido (debería ser "prod")
            "Project":        "brainmart",
            "Owner":          "team",
            "ComplianceLevel": "FDA-21CFR11"
          }
        }
      }
    }]
  }
  count(result) > 0
}
