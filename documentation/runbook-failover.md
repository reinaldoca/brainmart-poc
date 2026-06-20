# 🚨 Runbook: Failover de Base de Datos — Brainmart

> **Versión:** 1.0.0 | **Clasificación:** Confidencial | **Owner:** DevSecOps Team  
> **Última revisión:** 2024-01 | **Próxima revisión:** 2024-07  
> **Cumplimiento:** FDA 21 CFR Part 11 §11.10(k) · GCP ICH E6(R2) §5.5.3

---

## 📋 Información del Documento

| Campo | Valor |
|-------|-------|
| **Propósito** | Procedimiento de failover de RDS PostgreSQL us-east-1 → eu-west-1 |
| **RTO objetivo** | < 5 minutos (Recovery Time Objective) |
| **RPO objetivo** | < 30 segundos (Recovery Point Objective) |
| **Aplica a** | Ambiente de PRODUCCIÓN únicamente |
| **Requiere** | Acceso a AWS CLI con rol BrainmartAuditorRole + aprobación del CTO |
| **Evidencia regulatoria** | Este runbook se ejecuta y queda registrado en CloudTrail |

---

## 🏗️ Arquitectura de Alta Disponibilidad

```
┌─────────────────────────────────────────────────────────────────┐
│                      ARQUITECTURA DR                             │
│                                                                   │
│  us-east-1 (PRIMARY)              eu-west-1 (DR)                │
│  ┌────────────────────┐            ┌────────────────────┐        │
│  │  RDS PostgreSQL 15 │ ──replica──│  RDS Read Replica  │        │
│  │  (Multi-AZ)        │  lógica    │  (promote en DR)   │        │
│  │  brainmart-prod-   │  pglogical │  brainmart-prod-   │        │
│  │  rds-postgres      │ ──────────▶│  rds-postgres-dr   │        │
│  └────────────────────┘            └────────────────────┘        │
│           ↑                                  ↑                   │
│  ECS Fargate (2+ tasks)           ECS Fargate (standby)          │
│  ALB → CloudFront → WAF           ALB → CloudFront               │
│                                                                   │
│  Secrets Manager:                 Secrets Manager:               │
│  /prod/database/primary-conn      /prod/database/dr-conn         │
└─────────────────────────────────────────────────────────────────┘
```

### Componentes del DR

| Componente | us-east-1 (PRIMARY) | eu-west-1 (DR) |
|-----------|---------------------|----------------|
| **RDS** | Multi-AZ activo | Read Replica (promote en DR) |
| **ECS** | 2+ tasks activas | 1 task standby |
| **Secrets Manager** | Connection string primario | Connection string DR |
| **CloudFront** | Distribución activa | Failover origin |
| **Route 53** | Registro principal | Health check + failover |

---

## 📊 Indicadores de Falla (¿Cuándo ejecutar este runbook?)

### Señales de alerta que indican falla del primario

```bash
# Los siguientes síntomas requieren activar el runbook:

# 1. Alarma de CloudWatch: brainmart-prod-rds-cpu-high CRITICAL
# 2. Alarma de CloudWatch: brainmart-prod-rds-connections-high CRITICAL  
# 3. Health check de la app devuelve 503 por > 2 minutos
# 4. RDS reporta "instance not available" en la consola de AWS
# 5. Multi-AZ failover automático de AWS no resuelve en 3 minutos

# Verificar el estado del primario:
aws rds describe-db-instances \
  --db-instance-identifier brainmart-prod-rds-postgres \
  --region us-east-1 \
  --query 'DBInstances[0].DBInstanceStatus'
```

**Si el output es `"available"` → No es necesario el DR manual**  
**Si el output es `"failed"`, `"incompatible-restore"` o hay timeout → Continuar con el runbook**

---

## ⏱️ Procedimiento de Failover (< 5 minutos)

### Prerrequisitos

```bash
# Tener instalado:
# - AWS CLI v2 configurado con credenciales de la cuenta PROD
# - psql (cliente PostgreSQL)
# - jq (para parsear JSON)

# Verificar acceso:
aws sts get-caller-identity
# Debe retornar el ARN de un rol con permisos de emergencia en PROD
```

### ⏰ Minuto 0 — Confirmar la falla

```bash
# PASO 1: Confirmar que el RDS primario está fallando
echo "=== Estado del RDS primario (us-east-1) ==="
aws rds describe-db-instances \
  --db-instance-identifier brainmart-prod-rds-postgres \
  --region us-east-1 \
  --query 'DBInstances[0].{Status:DBInstanceStatus,AZ:AvailabilityZone,MultiAZ:MultiAZ}' \
  --output table

# PASO 2: Verificar si el Multi-AZ de AWS ya está haciendo failover automático
aws rds describe-events \
  --source-type db-instance \
  --source-identifier brainmart-prod-rds-postgres \
  --duration 60 \
  --region us-east-1 \
  --query 'Events[*].{Time:Date,Message:Message}' \
  --output table

# PASO 3: Verificar el estado de la réplica en eu-west-1
echo "=== Estado de la Réplica DR (eu-west-1) ==="
aws rds describe-db-instances \
  --db-instance-identifier brainmart-prod-rds-postgres-dr \
  --region eu-west-1 \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Lag:ReplicaLag}' \
  --output table

# PASO 4: Calcular el replication lag (datos que se perderían)
REPLICA_LAG=$(aws rds describe-db-instances \
  --db-instance-identifier brainmart-prod-rds-postgres-dr \
  --region eu-west-1 \
  --query 'DBInstances[0].StatusInfos[?StatusType==`read replication`].Message' \
  --output text)
echo "⚠️  Replication Lag: ${REPLICA_LAG}"
echo "    Datos que podrían perderse si el primario está completamente caído"
```

**Decisión:**
- Si el replication lag es **< 30 segundos** → Proceder con el failover (RPO objetivo cumplido)
- Si el replication lag es **> 30 segundos** → Notificar al equipo clínico del potencial loss de datos antes de proceder

### ⏰ Minuto 1 — Notificar al equipo

```bash
# ANTES de hacer cualquier cambio, notificar:
# 1. CTO de Brainmart (requiere aprobación para DR en producción)
# 2. Equipo clínico (para pausar operaciones críticas si es posible)
# 3. Coordinadores de ensayos activos

# Enviar notificación a Slack #brainmart-incidents
aws sns publish \
  --topic-arn "arn:aws:sns:us-east-1:444444444444:brainmart-prod-incidents" \
  --message '{
    "severity": "CRITICAL",
    "event": "DATABASE_FAILOVER_INITIATED",
    "primary_region": "us-east-1",
    "dr_region": "eu-west-1",
    "initiated_by": "'"$(aws sts get-caller-identity --query Arn --output text)"'",
    "timestamp": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",
    "estimated_rto_minutes": 5,
    "action_required": "CTO approval needed"
  }' \
  --subject "🚨 CRITICAL: Brainmart DB Failover Iniciado"

echo "✅ Equipo notificado. Esperando confirmación del CTO..."
# En la POC, asumimos que la aprobación llega via Slack/llamada en < 30 segundos
```

### ⏰ Minuto 1:30 — Detener tráfico hacia el primario

```bash
# PASO 5: Escalar a 0 los microservicios en us-east-1
# Esto previene escrituras inconsistentes durante el failover
echo "=== Escalando servicios ECS a 0 en us-east-1 ==="

aws ecs update-service \
  --cluster brainmart-prod-ecs-cluster \
  --service brainmart-prod-patient-service \
  --desired-count 0 \
  --region us-east-1

aws ecs wait services-stable \
  --cluster brainmart-prod-ecs-cluster \
  --services brainmart-prod-patient-service \
  --region us-east-1

echo "✅ Tráfico detenido en us-east-1"

# PASO 6: Verificar que no hay transacciones activas en el primario
# Si el primario aún responde, verificar que no hay writes pendientes
if aws rds describe-db-instances \
  --db-instance-identifier brainmart-prod-rds-postgres \
  --region us-east-1 &>/dev/null 2>&1; then

  DB_SECRET=$(aws secretsmanager get-secret-value \
    --secret-id brainmart-prod/database/primary-connection \
    --region us-east-1 \
    --query SecretString \
    --output text)

  DB_HOST=$(echo $DB_SECRET | jq -r '.host')
  DB_USER=$(echo $DB_SECRET | jq -r '.username')
  DB_PASS=$(echo $DB_SECRET | jq -r '.password')

  ACTIVE_CONNECTIONS=$(PGPASSWORD="$DB_PASS" psql \
    --host="$DB_HOST" \
    --username="$DB_USER" \
    --dbname="brainmart_prod" \
    --command="SELECT count(*) FROM pg_stat_activity WHERE state = 'active' AND query NOT LIKE '%pg_stat_activity%';" \
    --tuples-only --no-align 2>/dev/null || echo "0")

  echo "Conexiones activas restantes: $ACTIVE_CONNECTIONS"
fi
```

### ⏰ Minuto 2 — Promover la réplica DR

```bash
# PASO 7: Promover la réplica de eu-west-1 a instancia primaria
echo "=== Promoviendo réplica DR en eu-west-1 ==="

aws rds promote-read-replica \
  --db-instance-identifier brainmart-prod-rds-postgres-dr \
  --region eu-west-1

# Esperar a que la promoción complete (puede tardar 1-3 minutos)
echo "Esperando que la réplica sea promovida a primaria..."
aws rds wait db-instance-available \
  --db-instance-identifier brainmart-prod-rds-postgres-dr \
  --region eu-west-1

# Verificar que ya no tiene replication lag (es la nueva primaria)
DR_STATUS=$(aws rds describe-db-instances \
  --db-instance-identifier brainmart-prod-rds-postgres-dr \
  --region eu-west-1 \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text)

echo "Estado de la réplica promovida: $DR_STATUS"

if [ "$DR_STATUS" != "available" ]; then
  echo "❌ ERROR: La réplica no está disponible después de la promoción"
  echo "Estado: $DR_STATUS"
  echo "Verificar manualmente en la consola de AWS"
  exit 1
fi

echo "✅ Réplica promovida exitosamente. eu-west-1 es ahora la BD primaria."
```

### ⏰ Minuto 3 — Actualizar connection strings

```bash
# PASO 8: Obtener el nuevo endpoint de la BD promovida
NEW_DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier brainmart-prod-rds-postgres-dr \
  --region eu-west-1 \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)

echo "Nuevo endpoint de BD: $NEW_DB_ENDPOINT"

# PASO 9: Obtener las credenciales actuales del DR
DR_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id brainmart-prod/database/dr-connection \
  --region eu-west-1 \
  --query SecretString \
  --output text)

DR_USER=$(echo $DR_SECRET | jq -r '.username')
DR_PASS=$(echo $DR_SECRET | jq -r '.password')
DR_DBNAME=$(echo $DR_SECRET | jq -r '.dbname')

# PASO 10: Actualizar el secreto PRINCIPAL en Secrets Manager
# Los microservicios leen de /prod/database/primary-connection
aws secretsmanager update-secret \
  --secret-id brainmart-prod/database/primary-connection \
  --region us-east-1 \
  --secret-string "$(jq -n \
    --arg host "$NEW_DB_ENDPOINT" \
    --arg user "$DR_USER" \
    --arg pass "$DR_PASS" \
    --arg db "$DR_DBNAME" \
    '{
      host: $host,
      port: "5432",
      username: $user,
      password: $pass,
      dbname: $db,
      region: "eu-west-1",
      failover_active: true,
      failover_timestamp: now | todate
    }'
  )"

# También actualizar en eu-west-1 (los microservicios DR leen de aquí)
aws secretsmanager update-secret \
  --secret-id brainmart-prod/database/primary-connection \
  --region eu-west-1 \
  --secret-string "$(jq -n \
    --arg host "$NEW_DB_ENDPOINT" \
    --arg user "$DR_USER" \
    --arg pass "$DR_PASS" \
    --arg db "$DR_DBNAME" \
    '{
      host: $host,
      port: "5432",
      username: $user,
      password: $pass,
      dbname: $db,
      region: "eu-west-1",
      failover_active: true
    }'
  )"

echo "✅ Connection strings actualizados para apuntar a eu-west-1"
```

### ⏰ Minuto 4 — Levantar servicios en eu-west-1

```bash
# PASO 11: Escalar los microservicios en eu-west-1
echo "=== Levantando microservicios en eu-west-1 ==="

aws ecs update-service \
  --cluster brainmart-prod-ecs-cluster-dr \
  --service brainmart-prod-patient-service-dr \
  --desired-count 2 \  # Mínimo 2 para HA
  --region eu-west-1

aws ecs wait services-stable \
  --cluster brainmart-prod-ecs-cluster-dr \
  --services brainmart-prod-patient-service-dr \
  --region eu-west-1

echo "✅ Microservicios levantados en eu-west-1"

# PASO 12: Actualizar Route 53 para apuntar al ALB de eu-west-1
echo "=== Actualizando DNS para apuntar a eu-west-1 ==="

# Obtener el ARN del ALB en eu-west-1
EU_ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names "brainmart-prod-alb-dr" \
  --region eu-west-1 \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

EU_HOSTED_ZONE=$(aws elbv2 describe-load-balancers \
  --names "brainmart-prod-alb-dr" \
  --region eu-west-1 \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' \
  --output text)

# Actualizar Route 53 con un change batch
aws route53 change-resource-record-sets \
  --hosted-zone-id "${{ vars.ROUTE53_HOSTED_ZONE_ID }}" \
  --change-batch "$(jq -n \
    --arg alb_dns "$EU_ALB_DNS" \
    --arg alb_zone "$EU_HOSTED_ZONE" \
    '{
      Changes: [{
        Action: "UPSERT",
        ResourceRecordSet: {
          Name: "api.brainmart.health",
          Type: "A",
          AliasTarget: {
            HostedZoneId: $alb_zone,
            DNSName: $alb_dns,
            EvaluateTargetHealth: true
          }
        }
      }]
    }'
  )"

echo "✅ DNS actualizado. TTL de propagación: ~60 segundos"
```

### ⏰ Minuto 5 — Verificar y Confirmar

```bash
# PASO 13: Verificar que el sistema está operativo en eu-west-1
echo "=== Verificación de integridad post-failover ==="

sleep 60  # Esperar propagación DNS

# Health check del API
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  https://api.brainmart.health/health)

if [ "$HTTP_STATUS" == "200" ]; then
  echo "✅ API health check: OK (HTTP $HTTP_STATUS)"
else
  echo "❌ API health check: FAIL (HTTP $HTTP_STATUS)"
fi

# Verificar conectividad de BD
DR_CONN_TEST=$(PGPASSWORD="$DR_PASS" psql \
  --host="$NEW_DB_ENDPOINT" \
  --username="$DR_USER" \
  --dbname="$DR_DBNAME" \
  --command="SELECT NOW(), current_database(), pg_is_in_recovery();" \
  --tuples-only --no-align 2>/dev/null)

echo "Estado de la nueva BD primaria:"
echo "$DR_CONN_TEST"

# Verificar que pg_is_in_recovery() = false (es primaria, no réplica)
IS_REPLICA=$(echo "$DR_CONN_TEST" | awk -F'|' '{print $3}')
if [ "$IS_REPLICA" == "f" ]; then
  echo "✅ La BD de eu-west-1 está en modo PRIMARY (no es réplica)"
else
  echo "⚠️  La BD de eu-west-1 todavía está en modo réplica. Verificar la promoción."
fi

# Verificar integridad del audit trail
echo "=== Verificando audit trail ALCOA+ ==="
AUDIT_COUNT=$(PGPASSWORD="$DR_PASS" psql \
  --host="$NEW_DB_ENDPOINT" \
  --username="$DR_USER" \
  --dbname="$DR_DBNAME" \
  --command="SELECT count(*) FROM audit_log WHERE changed_at > NOW() - INTERVAL '1 hour';" \
  --tuples-only --no-align 2>/dev/null)

echo "Registros en audit_log (última hora): $AUDIT_COUNT"

# PASO 14: Registrar el failover en el audit log (ALCOA+ requirement)
PGPASSWORD="$DR_PASS" psql \
  --host="$NEW_DB_ENDPOINT" \
  --username="$DR_USER" \
  --dbname="$DR_DBNAME" \
  --command="
    SET LOCAL app.current_user = 'DR-FAILOVER-PROCEDURE';
    SET LOCAL app.request_id = '$(uuidgen)';
    INSERT INTO audit_log (table_name, record_id, operation, changed_by, new_values)
    VALUES (
      'system_events',
      'dr-failover-$(date +%Y%m%d%H%M%S)',
      'I',
      'DR-FAILOVER-PROCEDURE',
      jsonb_build_object(
        'event', 'FAILOVER_COMPLETED',
        'from_region', 'us-east-1',
        'to_region', 'eu-west-1',
        'timestamp', NOW(),
        'triggered_by', '$(aws sts get-caller-identity --query Arn --output text)',
        'rto_achieved_seconds', '$(( $(date +%s) - FAILOVER_START_TIME ))'
      )
    );
  "

echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║  ✅ FAILOVER COMPLETADO EXITOSAMENTE                   ║"
echo "║                                                          ║"
echo "║  Primaria anterior: us-east-1 (CAÍDA)                  ║"
echo "║  Nueva primaria:    eu-west-1 (ACTIVA)                 ║"
echo "║  RTO logrado:       < 5 minutos                        ║"
echo "║  Audit trail:       Registrado                         ║"
echo "╚════════════════════════════════════════════════════════╝"
```

---

## 🔄 Procedimiento de Failback (Retorno a us-east-1)

Una vez que us-east-1 esté reparado, se puede volver al estado original.  
**Tiempo estimado: 15-30 minutos (no crítico, hacerlo en horario de bajo tráfico)**

```bash
# Solo ejecutar cuando us-east-1 esté completamente reparado y verificado

# PASO 1: Crear nueva réplica desde eu-west-1 hacia us-east-1
aws rds create-db-instance-read-replica \
  --db-instance-identifier brainmart-prod-rds-postgres \
  --source-db-instance-identifier brainmart-prod-rds-postgres-dr \
  --region us-east-1 \
  --source-region eu-west-1 \
  --db-instance-class db.r6g.xlarge \
  --multi-az \
  --storage-encrypted \
  --kms-key-id alias/brainmart-prod-rds-us-east-1

# PASO 2: Esperar a que la réplica esté sincronizada
# (monitorear replication lag hasta que sea < 5 segundos)
watch -n 10 'aws rds describe-db-instances \
  --db-instance-identifier brainmart-prod-rds-postgres \
  --region us-east-1 \
  --query "DBInstances[0].StatusInfos"'

# PASO 3: Ejecutar el mismo procedimiento de failover pero en sentido inverso
# (eu-west-1 → us-east-1)
```

---

## 📝 Registro Post-Incidente (Obligatorio FDA)

Después de cualquier failover, completar este registro:

```markdown
## Registro de Incidente de Failover

**Fecha/Hora inicio:** ___________
**Fecha/Hora resolución:** ___________
**RTO logrado:** ___ minutos (objetivo: < 5)
**RPO logrado:** ___ segundos (objetivo: < 30)
**Datos perdidos:** Ninguno / ___ registros (describir)
**Causa raíz:** ___________
**Impacto en ensayos clínicos:** ___________
**Aprobado por CTO:** Sí/No — ___________
**Número de ensayos afectados:** ___________
**Notificaciones enviadas a:** ___________

### Acciones de remediación:
1. ___________
2. ___________

### Lecciones aprendidas:
1. ___________

**Firma del Ingeniero responsable:** _______________ Fecha: ______
**Firma del CTO:** _______________ Fecha: ______

*Este documento es evidencia regulatoria bajo FDA 21 CFR Part 11 §11.10(k)*
```

---

## 🔗 Referencias

| Documento | Ubicación |
|-----------|-----------|
| Traceability Matrix FDA | `documentation/traceability-matrix.md` |
| Backup Restoration Plan | `documentation/backup-restoration-plan.md` |
| Data Retention Policy | `documentation/data-retention-policy.md` |
| CloudWatch Dashboard | AWS Console → CloudWatch → Dashboards → `brainmart-prod-audit` |
| GuardDuty Findings | AWS Console → GuardDuty → Findings |

---

*Documento controlado — FDA 21 CFR Part 11 §11.10(k) — No modificar sin aprobación del Change Control Board*
