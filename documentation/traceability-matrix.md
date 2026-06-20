# 📋 Matriz de Trazabilidad — FDA 21 CFR Part 11 → Implementación

> **Versión:** 1.0.0 | **Fecha:** 2024-01 | **Clasificación:** Uso Interno  
> **Propósito:** Mapear cada requisito regulatorio a su implementación técnica demostrable

---

## 📜 FDA 21 CFR Part 11 — Electronic Records & Electronic Signatures

| ID Requisito | Texto del Requisito (resumen) | Implementación Técnica | Evidencia / Archivo |
|---|---|---|---|
| §11.10(a) | Validación de sistemas computarizados | Pipeline CI/CD con SAST+SCA+DAST antes de deploy | `pipeline/.github/workflows/ci-cd.yml` |
| §11.10(b) | Los registros deben ser legibles y recuperables | Formato Parquet en S3 + Athena queries | `modules/database/scripts/export-audit-to-s3.sql` |
| §11.10(c) | Protección de registros contra modificación | KMS CMK + S3 Object Lock GOVERNANCE 7 años | `modules/storage/main.tf` |
| §11.10(d) | Acceso limitado a personas autorizadas | IAM mínimo privilegio + MFA + JWT HttpOnly cookies | `governance/cloudformation-stacksets/iam-roles-stackset.yaml` |
| §11.10(e) | Audit trail seguro: quién, cuándo, qué | Triggers ALCOA+ en PostgreSQL → S3 → Athena | `modules/database/scripts/audit-triggers.sql` |
| §11.10(f) | Secuencia de pasos operacionales | Enforced via workflow de aplicación + triggers | `microservices/patient-service/src/PatientService/Controllers/PatientsController.cs` |
| §11.10(g) | Controles de autoridad de firma | JWT firmado con KMS + rotación automática 30d | `modules/secrets/main.tf` |
| §11.10(h) | Enlace firma→registro | JWT claim `sub` en `audit_log.application_user` | `modules/database/scripts/audit-triggers.sql` |
| §11.10(i) | Educación y entrenamiento | Documentado en runbook-failover.md + data-retention-policy.md | `documentation/` |
| §11.10(j) | Documentación de políticas | SCPs, Config Rules, Checkov, OPA | `governance/` + `infrastructure/policy-as-code/` |
| §11.10(k) | Control de cambios de sistemas | Pipeline CI/CD con aprobación manual para producción | `pipeline/.github/workflows/ci-cd.yml` → job `deploy-prod` |

---

## 🧪 GCP ICH E6(R2) — Good Clinical Practice

| Requisito GCP | Implementación | Archivo |
|---|---|---|
| §5.5.3 Sistemas computarizados validados | SAST (SonarQube) + SCA (Snyk) + DAST (ZAP) | `ci-cd.yml` |
| §5.5.3 Backup de datos | RDS backup 35 días + PITR | `environments/prod/database/terragrunt.hcl` |
| §5.5.3 Recuperación ante desastres | Failover eu-west-1 en <5 min | `documentation/runbook-failover.md` |
| §8.3.1 Retención de datos del ensayo | S3 Object Lock 7 años + Glacier | `modules/storage/main.tf` |

---

## 🔬 ALCOA+ — Principios de Integridad de Datos

| Principio | Implementación | Campo en audit_log |
|---|---|---|
| **A**ttributable | JWT claim `sub` + IP del cliente | `changed_by`, `application_user`, `ip_address` |
| **L**egible | Parquet en S3, queries en Athena, dashboard CloudWatch | CloudWatch Dashboard |
| **C**ontemporaneous | `NOW()` en UTC en el trigger (no timestamp del cliente) | `changed_at TIMESTAMPTZ DEFAULT NOW()` |
| **O**riginal | JSONB con el valor exacto antes del cambio | `old_values JSONB` |
| **A**ccurate | JSONB con el valor exacto después del cambio | `new_values JSONB` |
| **+** Complete | Triggers en INSERT + UPDATE + DELETE sin excepciones | `fn_audit_trigger()` |
| **+** Consistent | Timezone UTC forzado en `pg_parameter_group` | `timezone = UTC` |
| **+** Enduring | S3 Object Lock GOVERNANCE 7 años | `aws_s3_bucket_object_lock_configuration` |
| **+** Available | Athena Workgroup dedicado para queries de auditoría | `aws_athena_workgroup.audit` |

---

## 🇪🇺 GDPR — Reglamento General de Protección de Datos

| Artículo GDPR | Implementación | Archivo |
|---|---|---|
| Art. 25 — Privacidad por diseño | KMS envelope encryption para PHI + SCP anti-S3-público | `modules/database/scripts/audit-triggers.sql`, `governance/policies/` |
| Art. 32 — Seguridad del tratamiento | TLS 1.3, KMS CMK, MFA obligatorio | `modules/compute/main.tf`, `iam-roles-stackset.yaml` |
| Art. 44 — Transferencias internacionales | Replicación solo a eu-west-1 (dentro de la UE) | `environments/prod/dr-eu-west-1/` |
| Art. 17 — Derecho al olvido | `fn_anonymize_patient()` en PostgreSQL | `modules/database/scripts/audit-triggers.sql` |
| Art. 35 — DPIA | Geo-restriction WAF: solo USA, LATAM, España | `modules/storage/main.tf` |
