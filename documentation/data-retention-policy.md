# 📅 Política de Retención de Datos — Brainmart

> **Versión:** 1.0.0 | **Efectiva desde:** 2024-01-01  
> **Revisión anual obligatoria** | **Cumplimiento:** FDA 21 CFR Part 11 · GCP ICH E6(R2) · GDPR

---

## 📊 Tabla de Retención por Tipo de Dato

| Tipo de Dato | Sistema | Retención | Regulación | Método de Eliminación |
|---|---|---|---|---|
| Datos de pacientes (PHI activos) | RDS PostgreSQL | Duración del ensayo + 15 años | FDA 21 CFR §312.62 | Anonimización (`fn_anonymize_patient`) |
| Audit trail de cambios | S3 (Parquet) + RDS | **7 años** | FDA 21 CFR Part 11 §11.10(e) | S3 Object Lock expiration |
| Logs de CloudTrail | S3 + CloudWatch | 7 años | FDA 21 CFR Part 11 | S3 Lifecycle → Glacier → Delete |
| Logs de aplicación (.NET) | CloudWatch Logs | 2 años (prod) / 90 días (dev) | GCP | Log Group retention policy |
| VPC Flow Logs | CloudWatch Logs | 7 años (prod) / 90 días (dev) | Forensics | Log Group retention policy |
| Imágenes Docker | ECR | 30 versiones más recientes | Seguridad | ECR lifecycle policy |
| Estado de Terraform | S3 versionado | 90 versiones | Operacional | S3 lifecycle (versiones antiguas) |
| Backups RDS | AWS Snapshots | 35 días (automático) | GCP ICH E6(R2) | Eliminación automática por AWS |
| SBOMs | GitHub Releases | Indefinido | FDA (trazabilidad) | Nunca eliminar |

---

## 🔒 Implementación Técnica

### S3 Object Lock — Audit Logs (7 años)

```hcl
# modules/storage/main.tf
resource "aws_s3_bucket_object_lock_configuration" "audit" {
  rule {
    default_retention {
      mode  = "GOVERNANCE"  # Admin puede eliminar con permiso especial
      years = 7
    }
  }
}
```

### CloudWatch Logs Retention — Logs de Aplicación

```hcl
# modules/compute/main.tf
resource "aws_cloudwatch_log_group" "app" {
  retention_in_days = var.environment == "prod" ? 731 : 90
  # prod = 731 días (2 años) | dev/staging = 90 días
}
```

### S3 Lifecycle — Archivado automático a Glacier

```
0-12 meses   → S3 Standard (acceso frecuente: auditorías activas)
12-24 meses  → S3 Glacier (acceso infrecuente: auditorías históricas)
24-84 meses  → S3 Glacier Deep Archive (archivado a largo plazo)
84 meses+    → Eliminación automática (7 años cumplidos)
```

---

## 🇪🇺 GDPR — Derecho al Olvido vs. Retención Regulatoria

El GDPR establece el derecho al olvido (Art. 17), pero también reconoce
excepciones por obligaciones legales y regulatorias (Art. 17.3.b).

**Decisión de Brainmart:**
- Los **datos operacionales** del paciente se **anonimizan** cuando se solicita el olvido
- El **audit trail** (registro de cambios) se **conserva** como evidencia regulatoria FDA
- La **anonimización** misma queda registrada en el audit_log (paradoja resuelta)

```sql
-- Proceso de anonimización (GDPR Art. 17 compatible con FDA Art. 11.10(e))
SELECT fn_anonymize_patient('patient-uuid-here');
-- Resultado: datos PHI reemplazados con valores ficticios
-- audit_log: registro de la anonimización conservado (evidencia de cumplimiento GDPR)
```

---

*Documento revisado y aprobado por: DevSecOps Team, Legal, DPO*  
*Próxima revisión obligatoria: 2025-01-01*
