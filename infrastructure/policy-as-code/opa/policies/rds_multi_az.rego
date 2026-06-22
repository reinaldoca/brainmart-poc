# ──────────────────────────────────────────────────────────────────────────────
# infrastructure/policy-as-code/opa/policies/rds_multi_az.rego
#
# POLÍTICA OPA: Validar Multi-AZ en bases de datos de PRODUCCIÓN
#
# PROPÓSITO: Los ensayos clínicos en producción no pueden tolerar downtime
# de base de datos. Multi-AZ garantiza failover automático en < 2 minutos
# si la instancia primaria falla.
#
# CONTEXTO REGULATORIO:
#   - GCP ICH E6(R2) §5.5.3: Los sistemas deben tener continuidad de servicio
#   - FDA 21 CFR Part 11: Los sistemas de registros electrónicos deben estar
#     disponibles para auditorías en cualquier momento
#
# CÓMO FUNCIONA:
#   1. El pipeline genera el plan de Terraform: terraform show -json tfplan.binary
#   2. conftest test tfplan.json --policy policies/ valida el JSON contra este Rego
#   3. Si la policy falla, el pipeline se detiene ANTES del apply
#
# USO LOCAL:
#   terraform plan -out=tfplan.binary
#   terraform show -json tfplan.binary > tfplan.json
#   conftest test tfplan.json --policy . --namespace brainmart
# ──────────────────────────────────────────────────────────────────────────────

package brainmart.rds

import rego.v1

# ── REGLA PRINCIPAL: deny ──
# OPA evalúa todas las reglas 'deny'. Si alguna produce un mensaje,
# conftest reporta la violación y el pipeline falla.

# Regla: las instancias RDS en producción DEBEN tener multi_az = true
deny contains msg if {
    # Recorrer todos los cambios planificados en el plan de Terraform
    some resource in input.resource_changes

    # Solo evaluar instancias RDS (aws_db_instance)
    resource.type == "aws_db_instance"

    # Solo evaluar recursos que se van a crear o actualizar (no destruir)
    action_creates_or_updates(resource.change.actions)

    # Obtener la configuración después del apply
    config := resource.change.after

    # Verificar si este recurso es de producción
    is_production_resource(config)

    # Verificar que multi_az NO está habilitado
    not config.multi_az

    # Construir el mensaje de error con toda la información necesaria
    msg := sprintf(
        "❌ [RDS Multi-AZ PROD] Instancia RDS '%s' en producción debe tener multi_az = true. " +
        "Requisito: GCP ICH E6(R2) §5.5.3 y FDA 21 CFR Part 11 (disponibilidad). " +
        "Ambiente detectado: '%s'. Instance class: '%s'.",
        [resource.address, config.tags.Environment, config.instance_class]
    )
}

# Regla: las instancias RDS en producción DEBEN tener backup_retention_period >= 35
deny contains msg if {
    some resource in input.resource_changes

    resource.type == "aws_db_instance"
    action_creates_or_updates(resource.change.actions)

    config := resource.change.after

    is_production_resource(config)

    # Verificar que el backup_retention_period es insuficiente
    config.backup_retention_period < 35

    msg := sprintf(
        "❌ [RDS Backup PROD] Instancia RDS '%s' en producción tiene backup_retention_period = %d días. " +
        "Mínimo requerido: 35 días (GCP ICH E6(R2) Requisito de retención de datos de ensayos clínicos). " +
        "Actual: %d días.",
        [resource.address, config.backup_retention_period, config.backup_retention_period]
    )
}

# Regla: las instancias RDS SIEMPRE deben tener cifrado habilitado
deny contains msg if {
    some resource in input.resource_changes

    resource.type == "aws_db_instance"
    action_creates_or_updates(resource.change.actions)

    config := resource.change.after

    # Esta regla aplica a TODOS los ambientes (no solo prod)
    not config.storage_encrypted

    msg := sprintf(
        "❌ [RDS Encryption] Instancia RDS '%s' no tiene storage_encrypted = true. " +
        "OBLIGATORIO en todos los ambientes. " +
        "Requisito: FDA 21 CFR Part 11 §11.10(c) - cifrado de datos de PHI. " +
        "El SCP de Capa 0 también bloqueará este deploy en AWS.",
        [resource.address]
    )
}

# Regla: las instancias RDS en producción DEBEN tener deletion_protection = true
deny contains msg if {
    some resource in input.resource_changes

    resource.type == "aws_db_instance"
    action_creates_or_updates(resource.change.actions)

    config := resource.change.after

    is_production_resource(config)

    not config.deletion_protection

    msg := sprintf(
        "❌ [RDS Deletion Protection] Instancia RDS '%s' en producción debe tener " +
        "deletion_protection = true para prevenir eliminación accidental de datos de pacientes. " +
        "Requisito: GCP ICH E6(R2) - preservación de datos de ensayos clínicos.",
        [resource.address]
    )
}

# ── FUNCIONES AUXILIARES ──

# Determina si un resource action crea o actualiza (no destruye ni no-op)
action_creates_or_updates(actions) if {
    actions[_] in {"create", "update"}
}

# Determina si un recurso es de producción basándose en sus tags o nombre
is_production_resource(config) if {
    config.tags.Environment == "prod"
}

is_production_resource(config) if {
    config.tags.Environment == "production"
}

# También detectar por el identificador del recurso (brainmart-prod-*)
is_production_resource(config) if {
    contains(config.identifier, "-prod-")
}

# ── REGLAS DE ADVERTENCIA (warn) ──
# Las advertencias no fallan el pipeline pero aparecen en el reporte

# Advertencia: staging debería tener backup_retention_period >= 14 días
warn contains msg if {
    some resource in input.resource_changes

    resource.type == "aws_db_instance"
    action_creates_or_updates(resource.change.actions)

    config := resource.change.after

    config.tags.Environment in {"staging", "uat"}
    config.backup_retention_period < 14

    msg := sprintf(
        "⚠️  [RDS Backup STAGING] Instancia RDS '%s' en staging tiene solo %d días de backup. " +
        "Recomendado: >= 14 días para staging (permite rollback de releases de 2 semanas).",
        [resource.address, config.backup_retention_period]
    )
}
