# ──────────────────────────────────────────────────────────────────────────────
# infrastructure/policy-as-code/opa/policies/required_tags.rego
#
# POLÍTICA OPA: Todos los recursos deben tener tags de compliance obligatorios
#
# TAGS REQUERIDOS:
#   Environment    → dev / staging / prod (para saber dónde está el recurso)
#   Project        → brainmart (para cost allocation y búsqueda)
#   Owner          → equipo responsable (para incidents y auditorías)
#   ComplianceLevel → nivel regulatorio aplicable (FDA-21CFR11, GCP, etc.)
#
# POR QUÉ IMPORTA:
#   - FDA 21 CFR Part 11: los recursos deben ser identificables y trazables
#   - Cost allocation: saber qué ensayo clínico genera qué costo
#   - Incident response: saber quién es responsable de cada recurso
#   - AWS Config Rule de Capa 0 complementa esta verificación en runtime
# ──────────────────────────────────────────────────────────────────────────────

package brainmart.tags

import future.keywords.in
import future.keywords.if
import future.keywords.every

# ── Tags obligatorios para TODOS los recursos ──
required_tags := {
    "Environment",
    "Project",
    "Owner",
    "ComplianceLevel"
}

# ── Tipos de recursos que requieren los tags de compliance ──
# (Recursos que pueden contener o procesar datos de pacientes)
tagged_resource_types := {
    "aws_instance",
    "aws_db_instance",
    "aws_rds_cluster",
    "aws_s3_bucket",
    "aws_ecs_cluster",
    "aws_ecs_service",
    "aws_ecs_task_definition",
    "aws_lambda_function",
    "aws_elasticache_cluster",
    "aws_vpc",
    "aws_subnet",
    "aws_security_group",
    "aws_kms_key",
    "aws_secretsmanager_secret",
    "aws_cloudwatch_log_group"
}

# ── REGLA PRINCIPAL: deny ──

# Regla: recursos sin el conjunto completo de tags obligatorios
deny contains msg if {
    some resource in input.resource_changes

    # Solo evaluar tipos de recursos que requieren tags
    resource.type in tagged_resource_types

    # Solo recursos que se van a crear o actualizar
    resource.change.actions[_] in {"create", "update"}

    config := resource.change.after

    # Encontrar qué tags faltan
    missing := missing_tags(config)

    # Solo fallar si hay tags faltantes
    count(missing) > 0

    msg := sprintf(
        "❌ [Tags Compliance] Recurso '%s' (tipo: %s) le faltan los siguientes tags obligatorios: %v. " +
        "Tags requeridos: %v. " +
        "Tags actuales: %v. " +
        "Los tags de compliance son obligatorios para trazabilidad FDA/GCP/GDPR. " +
        "Configurar en el root terragrunt.hcl o en el inputs del módulo.",
        [
            resource.address,
            resource.type,
            missing,
            required_tags,
            object.keys(object.get(config, "tags", {}))
        ]
    )
}

# Regla: el tag Environment debe tener un valor válido
deny contains msg if {
    some resource in input.resource_changes

    resource.type in tagged_resource_types
    resource.change.actions[_] in {"create", "update"}

    config := resource.change.after

    tags := object.get(config, "tags", {})
    env_value := object.get(tags, "Environment", "")

    # El valor no puede estar vacío
    env_value != ""

    # El valor debe ser uno de los ambientes válidos
    not env_value in {"dev", "staging", "prod", "shared-services", "production"}

    msg := sprintf(
        "❌ [Tags Validation] Recurso '%s' tiene el tag Environment = '%s' que no es válido. " +
        "Valores permitidos: dev, staging, prod, shared-services. " +
        "Verificar el account.hcl del ambiente.",
        [resource.address, env_value]
    )
}

# Regla: el tag Project debe ser "brainmart"
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
        "❌ [Tags Validation] Recurso '%s' tiene el tag Project = '%s'. " +
        "Debe ser 'brainmart'. Revisar el input 'project' en el root terragrunt.hcl.",
        [resource.address, project_value]
    )
}

# Regla: el tag ComplianceLevel debe indicar el nivel correcto
deny contains msg if {
    some resource in input.resource_changes

    resource.type in {"aws_db_instance", "aws_rds_cluster", "aws_s3_bucket"}
    resource.change.actions[_] in {"create", "update"}

    config := resource.change.after

    tags := object.get(config, "tags", {})
    compliance_level := object.get(tags, "ComplianceLevel", "")

    compliance_level != ""

    # Para BD y S3 con datos de pacientes, el nivel mínimo debe incluir FDA
    not contains(compliance_level, "FDA")

    msg := sprintf(
        "❌ [Tags ComplianceLevel] Recurso de datos '%s' (tipo: %s) tiene ComplianceLevel = '%s' " +
        "que no menciona FDA. Los recursos con datos de pacientes deben tener " +
        "ComplianceLevel que incluya 'FDA' (ej: 'FDA-21CFR11-GCP-ALCOA-GDPR'). " +
        "Revisar el compliance_level en el root terragrunt.hcl.",
        [resource.address, resource.type, compliance_level]
    )
}

# ── FUNCIONES AUXILIARES ──

# Retorna el conjunto de tags que faltan en la configuración del recurso
missing_tags(config) := missing if {
    # Obtener los tags actuales del recurso
    # Nota: Terragrunt agrega los default_tags del provider, que Checkov sí considera
    # pero el plan JSON de terraform show puede no incluirlos todos
    actual_tags := object.get(config, "tags", {})
    existing_tag_keys := {key | some key, _ in actual_tags}
    missing := required_tags - existing_tag_keys
}

# ── REGLAS DE ADVERTENCIA ──

# Advertencia: recursos sin tag CostCenter (no obligatorio pero recomendado)
warn contains msg if {
    some resource in input.resource_changes

    resource.type in {"aws_db_instance", "aws_ecs_service", "aws_lambda_function"}
    resource.change.actions[_] in {"create", "update"}

    config := resource.change.after

    tags := object.get(config, "tags", {})
    not "CostCenter" in object.keys(tags)

    msg := sprintf(
        "⚠️  [Tags CostCenter] Recurso '%s' no tiene el tag CostCenter. " +
        "Recomendado para asignación de costos por ensayo clínico. " +
        "Ejemplo: CostCenter = 'trial-NCT-2024-001'.",
        [resource.address]
    )
}

# ── REGLA DE AYUDA: allow ──
# OPA permite definir reglas 'allow' para documentar qué está permitido

# Los recursos de tipo 'data' (data sources) no necesitan tags
allow if {
    input.resource_changes[_].mode == "data"
}
