# 💾 Plan de Backup y Restauración — Brainmart

> **RTO:** < 5 minutos (failover automático Multi-AZ) | < 30 min (restauración PITR)  
> **RPO:** < 30 segundos (replicación lógica a eu-west-1)

---

## 🗂️ Inventario de Backups

| Componente | Tipo | Retención | Ubicación | Frecuencia |
|---|---|---|---|---|
| RDS PostgreSQL | Snapshot automático | **35 días** | AWS Managed | Continuo (PITR) |
| RDS PostgreSQL | Snapshot manual pre-deploy | 90 días | AWS Managed | Antes de cada release |
| audit_log (Parquet) | S3 Object Lock | **7 años** | `s3://brainmart-prod-audit-logs/` | Cada hora |
| Terraform State | S3 versionado | Indefinido (90 versiones) | `s3://brainmart-tfstate-*/` | Cada apply |
| Imágenes Docker | ECR | 30 versiones | ECR privado | Cada build |

---

## 🔄 Procedimientos de Restauración

### A. Restauración PITR — pérdida de datos accidental

```bash
# Restaurar la BD al estado de hace N minutos (Point In Time Recovery)
# ÚTIL PARA: borrado accidental de registros, migración fallida

RESTORE_TIME="2024-01-15T14:30:00Z"  # Timestamp antes del incidente (UTC)
NEW_INSTANCE_ID="brainmart-prod-rds-restored-$(date +%Y%m%d%H%M)"

aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier brainmart-prod-rds-postgres \
  --target-db-instance-identifier "$NEW_INSTANCE_ID" \
  --restore-time "$RESTORE_TIME" \
  --db-instance-class db.r6g.xlarge \
  --multi-az \
  --storage-encrypted \
  --kms-key-id alias/brainmart-prod-rds \
  --region us-east-1

# Esperar a que esté disponible (~15-30 minutos)
aws rds wait db-instance-available \
  --db-instance-identifier "$NEW_INSTANCE_ID" \
  --region us-east-1

echo "✅ Instancia restaurada: $NEW_INSTANCE_ID"
echo "   Verificar integridad antes de actualizar el connection string"
```

### B. Restauración desde Snapshot manual

```bash
# Listar snapshots disponibles
aws rds describe-db-snapshots \
  --db-instance-identifier brainmart-prod-rds-postgres \
  --snapshot-type manual \
  --query 'DBSnapshots[*].{Id:DBSnapshotIdentifier,Time:SnapshotCreateTime,Status:Status}' \
  --output table

# Restaurar desde snapshot específico
SNAPSHOT_ID="brainmart-prod-rds-pre-deploy-20240115"
aws rds restore-db-instance-from-db-snapshot \
  --db-snapshot-identifier "$SNAPSHOT_ID" \
  --db-instance-identifier brainmart-prod-rds-restored \
  --db-instance-class db.r6g.xlarge \
  --multi-az \
  --region us-east-1
```

### C. Consultar audit_log histórico en S3 (Athena)

```sql
-- Consultar todas las modificaciones a un paciente en los últimos 30 días
SELECT
    audit_id,
    operation_name,
    changed_by,
    application_user,
    ip_address,
    changed_at_utc,
    changed_fields,
    integrity_valid
FROM "brainmart_prod_audit"."audit_log"
WHERE table_name = 'patients'
  AND record_id  = '{{patient_uuid}}'
  AND partition_date >= DATE_ADD('day', -30, CURRENT_DATE)
ORDER BY changed_at_utc ASC;

-- Verificar que no hubo modificaciones no autorizadas (integrity check)
SELECT
    COUNT(*) AS total_records,
    COUNT(*) FILTER (WHERE integrity_valid = true)  AS valid_records,
    COUNT(*) FILTER (WHERE integrity_valid = false) AS tampered_records
FROM "brainmart_prod_audit"."audit_log"
WHERE partition_year = 2024
  AND partition_month = 1;
```

---

## ✅ Pruebas de Backup Programadas

| Frecuencia | Prueba | Responsable |
|---|---|---|
| Mensual | Restauración PITR en entorno de staging | DevSecOps Team |
| Trimestral | Failover completo DR (eu-west-1) | DevSecOps + CTO |
| Semestral | Restauración completa desde cero | DevSecOps Team |

*Todas las pruebas se registran en el audit_log y quedan como evidencia regulatoria.*
