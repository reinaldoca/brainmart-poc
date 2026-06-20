# ──────────────────────────────────────────────────────────────────────────────
# infrastructure/policy-as-code/opa/tests/rds_multi_az_test.rego
# Tests unitarios para las políticas OPA de RDS
# Ejecutar: opa test policies/ tests/ --verbose
# ──────────────────────────────────────────────────────────────────────────────

package brainmart.rds_test

import data.brainmart.rds

# ── Test: RDS en prod SIN multi_az DEBE fallar ────────────────────────────────
test_rds_prod_without_multi_az_fails if {
  result := rds.deny with input as {
    "resource_changes": [{
      "address": "module.database.aws_db_instance.main",
      "type":    "aws_db_instance",
      "change":  {
        "actions": ["create"],
        "after": {
          "identifier":               "brainmart-prod-rds-postgres",
          "instance_class":           "db.r6g.xlarge",
          "multi_az":                 false,
          "storage_encrypted":        true,
          "backup_retention_period":  35,
          "deletion_protection":      true,
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
  count(result) > 0  # Debe haber al menos 1 violación
}

# ── Test: RDS en prod CON multi_az DEBE pasar ─────────────────────────────────
test_rds_prod_with_multi_az_passes if {
  result := rds.deny with input as {
    "resource_changes": [{
      "address": "module.database.aws_db_instance.main",
      "type":    "aws_db_instance",
      "change":  {
        "actions": ["create"],
        "after": {
          "identifier":               "brainmart-prod-rds-postgres",
          "instance_class":           "db.r6g.xlarge",
          "multi_az":                 true,  # ← CORRECTO
          "storage_encrypted":        true,
          "backup_retention_period":  35,
          "deletion_protection":      true,
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
  count(result) == 0  # No debe haber violaciones
}

# ── Test: RDS en dev SIN multi_az DEBE pasar (no es requisito en dev) ─────────
test_rds_dev_without_multi_az_passes if {
  result := rds.deny with input as {
    "resource_changes": [{
      "address": "module.database.aws_db_instance.main",
      "type":    "aws_db_instance",
      "change":  {
        "actions": ["create"],
        "after": {
          "identifier":               "brainmart-dev-rds-postgres",
          "instance_class":           "db.t3.medium",
          "multi_az":                 false,  # Permitido en dev
          "storage_encrypted":        true,
          "backup_retention_period":  7,
          "deletion_protection":      false,
          "tags": {
            "Environment":    "dev",
            "Project":        "brainmart",
            "Owner":          "devsecops-team@brainmart.health",
            "ComplianceLevel": "FDA-21CFR11-GCP-ALCOA-GDPR"
          }
        }
      }
    }]
  }
  # El único deny debe ser por backup < 35 (que en dev es aceptable)
  # Para multi_az en dev, no debe haber deny
  every msg in result {
    not contains(msg, "multi_az")
  }
}

# ── Test: RDS sin cifrado SIEMPRE falla (en cualquier ambiente) ───────────────
test_rds_unencrypted_always_fails if {
  result := rds.deny with input as {
    "resource_changes": [{
      "address": "module.database.aws_db_instance.main",
      "type":    "aws_db_instance",
      "change":  {
        "actions": ["create"],
        "after": {
          "identifier":               "brainmart-dev-rds-postgres",
          "multi_az":                 false,
          "storage_encrypted":        false,  # ← INCORRECTO en CUALQUIER ambiente
          "backup_retention_period":  7,
          "deletion_protection":      false,
          "tags": {"Environment": "dev", "Project": "brainmart",
                   "Owner": "test", "ComplianceLevel": "FDA-21CFR11"}
        }
      }
    }]
  }
  count(result) > 0
}

# ── Test: prod con backup < 35 días DEBE fallar ───────────────────────────────
test_rds_prod_insufficient_backup_fails if {
  result := rds.deny with input as {
    "resource_changes": [{
      "address": "module.database.aws_db_instance.main",
      "type":    "aws_db_instance",
      "change":  {
        "actions": ["create"],
        "after": {
          "identifier":               "brainmart-prod-rds-postgres",
          "multi_az":                 true,
          "storage_encrypted":        true,
          "backup_retention_period":  7,  # ← INSUFICIENTE para prod (requiere 35)
          "deletion_protection":      true,
          "tags": {"Environment": "prod", "Project": "brainmart",
                   "Owner": "test", "ComplianceLevel": "FDA-21CFR11"}
        }
      }
    }]
  }
  count(result) > 0
}
