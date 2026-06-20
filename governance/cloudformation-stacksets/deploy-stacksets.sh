#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# deploy-stacksets.sh
# Orquestador de CloudFormation StackSets para la organización Brainmart
#
# PROPÓSITO: Despliega los 3 StackSets de Capa 0 en el orden correcto:
#   1. IAM Roles (prerequisito para los demás)
#   2. SCP Policies (gobernanza preventiva)
#   3. Config Rules + GuardDuty + CloudTrail (gobernanza detectiva)
#
# USO:
#   ./deploy-stacksets.sh [--dry-run] [--region us-east-1] [--account-filter dev]
#
# PREREQUISITOS:
#   - AWS CLI configurado con credenciales de la cuenta MASTER
#   - La cuenta debe ser la Master de la organización AWS
#   - Organizations debe tener "All Features" habilitadas (no solo Consolidated Billing)
#
# CUMPLIMIENTO: FDA 21 CFR Part 11 §11.10(k) - Control de cambios
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail  # -e: exit on error, -u: error on undefined var, -o pipefail: pipe errors

# ── Colores para output legible ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ── Funciones de logging ──
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_section() { echo -e "\n${CYAN}══════════════════════════════════════════${NC}"; echo -e "${CYAN} $*${NC}"; echo -e "${CYAN}══════════════════════════════════════════${NC}\n"; }

# ── Valores por defecto ──
DRY_RUN=false
PRIMARY_REGION="us-east-1"
DR_REGION="eu-west-1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Leer variables de entorno (con valores de ejemplo por defecto) ──
MASTER_ACCOUNT_ID="${AWS_MASTER_ACCOUNT_ID:-}"
SHARED_SERVICES_ACCOUNT_ID="${AWS_SHARED_SERVICES_ACCOUNT_ID:-}"
ORG_ID="${AWS_ORG_ID:-}"
ROOT_OU_ID="${AWS_ROOT_OU_ID:-}"
SNS_ALERT_TOPIC_ARN="${SNS_ALERT_TOPIC_ARN:-}"
AUDIT_BUCKET_NAME="${AUDIT_BUCKET_NAME:-brainmart-audit-logs-${MASTER_ACCOUNT_ID}}"

# ── Parsear argumentos de línea de comandos ──
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --region)
      PRIMARY_REGION="$2"
      shift 2
      ;;
    --help|-h)
      echo "Uso: $0 [--dry-run] [--region REGION]"
      echo ""
      echo "Variables de entorno requeridas:"
      echo "  AWS_MASTER_ACCOUNT_ID         ID de la cuenta master de la organización"
      echo "  AWS_SHARED_SERVICES_ACCOUNT_ID  ID de la cuenta de CI/CD"
      echo "  AWS_ORG_ID                    ID de la organización (o-xxxxxxxxxx)"
      echo "  AWS_ROOT_OU_ID                ID del OU raíz (r-xxxx)"
      echo "  SNS_ALERT_TOPIC_ARN           ARN del topic SNS para alertas"
      exit 0
      ;;
    *)
      log_error "Argumento desconocido: $1"
      exit 1
      ;;
  esac
done

# ──────────────────────────────────────────────────────────────────────────────
# FUNCIÓN: Validar prerrequisitos
# ──────────────────────────────────────────────────────────────────────────────
validate_prerequisites() {
  log_section "🔍 Validando Prerrequisitos"

  # Verificar que AWS CLI está instalado
  if ! command -v aws &> /dev/null; then
    log_error "AWS CLI no está instalado. Instalar: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
    exit 1
  fi
  log_success "AWS CLI instalado: $(aws --version 2>&1 | head -1)"

  # Verificar que jq está instalado (necesario para parsear respuestas JSON)
  if ! command -v jq &> /dev/null; then
    log_error "jq no está instalado. Instalar: brew install jq"
    exit 1
  fi
  log_success "jq instalado: $(jq --version)"

  # Verificar variables de entorno requeridas
  local required_vars=("AWS_MASTER_ACCOUNT_ID" "AWS_SHARED_SERVICES_ACCOUNT_ID" "AWS_ORG_ID" "AWS_ROOT_OU_ID" "SNS_ALERT_TOPIC_ARN")
  for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      log_error "Variable de entorno requerida no definida: $var"
      log_error "Copiar .env.example a .env y completar los valores"
      exit 1
    fi
    log_success "Variable $var: ${!var}"
  done

  # Verificar que las credenciales AWS son de la cuenta Master
  local current_account
  current_account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "ERROR")
  if [[ "$current_account" == "ERROR" ]]; then
    log_error "No se pudo obtener la identidad de AWS. Verificar las credenciales."
    exit 1
  fi
  if [[ "$current_account" != "$MASTER_ACCOUNT_ID" ]]; then
    log_error "Las credenciales actuales son de la cuenta $current_account"
    log_error "Este script debe ejecutarse con credenciales de la cuenta Master: $MASTER_ACCOUNT_ID"
    exit 1
  fi
  log_success "Credenciales de la cuenta Master correctas: $current_account"

  # Verificar que Organizations tiene All Features habilitadas
  local org_feature_set
  org_feature_set=$(aws organizations describe-organization --query 'Organization.FeatureSet' --output text)
  if [[ "$org_feature_set" != "ALL" ]]; then
    log_error "La organización AWS no tiene 'All Features' habilitadas."
    log_error "Las SCPs solo funcionan con 'All Features'. Estado actual: $org_feature_set"
    exit 1
  fi
  log_success "AWS Organizations con All Features habilitadas"

  # Verificar que el bucket de auditoría existe (o crearlo)
  if ! aws s3api head-bucket --bucket "$AUDIT_BUCKET_NAME" 2>/dev/null; then
    log_warning "Bucket de auditoría no existe: $AUDIT_BUCKET_NAME"
    if [[ "$DRY_RUN" == "false" ]]; then
      create_audit_bucket
    else
      log_info "[DRY-RUN] Se crearía el bucket: $AUDIT_BUCKET_NAME"
    fi
  else
    log_success "Bucket de auditoría existe: $AUDIT_BUCKET_NAME"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# FUNCIÓN: Crear bucket de auditoría centralizado
# Este bucket recibe logs de CloudTrail, Config y GuardDuty de TODAS las cuentas
# ──────────────────────────────────────────────────────────────────────────────
create_audit_bucket() {
  log_info "Creando bucket de auditoría centralizado: $AUDIT_BUCKET_NAME"

  aws s3api create-bucket \
    --bucket "$AUDIT_BUCKET_NAME" \
    --region "$PRIMARY_REGION"

  # Habilitar versionado (inmutabilidad de logs)
  aws s3api put-bucket-versioning \
    --bucket "$AUDIT_BUCKET_NAME" \
    --versioning-configuration Status=Enabled

  # Habilitar cifrado con KMS
  aws s3api put-bucket-encryption \
    --bucket "$AUDIT_BUCKET_NAME" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "aws:kms"
        },
        "BucketKeyEnabled": true
      }]
    }'

  # Bloquear acceso público (no puede ser público nunca)
  aws s3api put-public-access-block \
    --bucket "$AUDIT_BUCKET_NAME" \
    --public-access-block-configuration '{
      "BlockPublicAcls": true,
      "IgnorePublicAcls": true,
      "BlockPublicPolicy": true,
      "RestrictPublicBuckets": true
    }'

  # Política del bucket: permitir que CloudTrail de TODA la organización escriba aquí
  aws s3api put-bucket-policy \
    --bucket "$AUDIT_BUCKET_NAME" \
    --policy '{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Sid": "AllowCloudTrailOrgWrite",
          "Effect": "Allow",
          "Principal": {"Service": "cloudtrail.amazonaws.com"},
          "Action": ["s3:GetBucketAcl", "s3:PutObject"],
          "Resource": [
            "arn:aws:s3:::'"$AUDIT_BUCKET_NAME"'",
            "arn:aws:s3:::'"$AUDIT_BUCKET_NAME"'/cloudtrail/*"
          ],
          "Condition": {
            "StringEquals": {
              "aws:SourceOrgID": "'"$ORG_ID"'"
            }
          }
        },
        {
          "Sid": "AllowConfigOrgWrite",
          "Effect": "Allow",
          "Principal": {"Service": "config.amazonaws.com"},
          "Action": "s3:PutObject",
          "Resource": "arn:aws:s3:::'"$AUDIT_BUCKET_NAME"'/config/*",
          "Condition": {
            "StringEquals": {
              "aws:SourceOrgID": "'"$ORG_ID"'"
            }
          }
        }
      ]
    }'

  # Lifecycle: mover a Glacier después de 1 año, eliminar después de 7 años
  aws s3api put-bucket-lifecycle-configuration \
    --bucket "$AUDIT_BUCKET_NAME" \
    --lifecycle-configuration '{
      "Rules": [{
        "ID": "AuditLogsRetention",
        "Status": "Enabled",
        "Transitions": [
          {"Days": 365, "StorageClass": "GLACIER"},
          {"Days": 730, "StorageClass": "DEEP_ARCHIVE"}
        ],
        "Expiration": {"Days": 2555},
        "NoncurrentVersionExpiration": {"NoncurrentDays": 90}
      }]
    }'

  log_success "Bucket de auditoría creado y configurado: $AUDIT_BUCKET_NAME"
}

# ──────────────────────────────────────────────────────────────────────────────
# FUNCIÓN: Habilitar confianza de servicios en Organizations
# Necesario para que StackSets se desplieguen automáticamente en nuevas cuentas
# ──────────────────────────────────────────────────────────────────────────────
enable_trusted_access() {
  log_section "🔐 Habilitando Acceso Confiado en Organizations"

  local services=(
    "cloudformation.amazonaws.com"      # Para StackSets
    "config.amazonaws.com"              # Para Config Org-wide
    "guardduty.amazonaws.com"           # Para GuardDuty Org-wide
    "cloudtrail.amazonaws.com"          # Para CloudTrail Org-wide
  )

  for service in "${services[@]}"; do
    log_info "Habilitando trusted access para: $service"
    if [[ "$DRY_RUN" == "false" ]]; then
      aws organizations enable-aws-service-access \
        --service-principal "$service" 2>/dev/null || \
        log_warning "Ya estaba habilitado o no se puede habilitar: $service"
    else
      log_info "[DRY-RUN] Se habilitaría trusted access para: $service"
    fi
  done

  # Habilitar StackSets de confianza (para despliegue automático en OU)
  if [[ "$DRY_RUN" == "false" ]]; then
    aws cloudformation activate-organizations-access 2>/dev/null || \
      log_warning "Organizations access ya estaba activado en CloudFormation"
  fi

  log_success "Trusted access habilitado para todos los servicios"
}

# ──────────────────────────────────────────────────────────────────────────────
# FUNCIÓN: Desplegar un StackSet
# $1: nombre del StackSet
# $2: ruta al template
# $3: parámetros en formato JSON
# ──────────────────────────────────────────────────────────────────────────────
deploy_stackset() {
  local stackset_name="$1"
  local template_file="$2"
  local parameters="$3"
  local description="$4"

  log_info "Desplegando StackSet: $stackset_name"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Se desplegaría el StackSet: $stackset_name desde $template_file"
    return 0
  fi

  # Verificar si el StackSet ya existe
  if aws cloudformation describe-stack-set --stack-set-name "$stackset_name" &>/dev/null; then
    log_info "StackSet $stackset_name ya existe, actualizando..."
    aws cloudformation update-stack-set \
      --stack-set-name "$stackset_name" \
      --template-body "file://${template_file}" \
      --parameters "$parameters" \
      --capabilities CAPABILITY_NAMED_IAM \
      --permission-model SERVICE_MANAGED \
      --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
      --operation-preferences '{
        "RegionConcurrencyType": "PARALLEL",
        "MaxConcurrentPercentage": 100,
        "FailureTolerancePercentage": 10
      }' || log_warning "No hay cambios en el StackSet $stackset_name"
  else
    log_info "Creando nuevo StackSet: $stackset_name"
    aws cloudformation create-stack-set \
      --stack-set-name "$stackset_name" \
      --description "$description" \
      --template-body "file://${template_file}" \
      --parameters "$parameters" \
      --capabilities CAPABILITY_NAMED_IAM \
      --permission-model SERVICE_MANAGED \
      --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false

    # Desplegar en todas las cuentas de la organización bajo el OU raíz
    aws cloudformation create-stack-instances \
      --stack-set-name "$stackset_name" \
      --deployment-targets OrganizationalUnitIds=["$ROOT_OU_ID"] \
      --regions "$PRIMARY_REGION" "$DR_REGION" \
      --operation-preferences '{
        "RegionConcurrencyType": "PARALLEL",
        "MaxConcurrentPercentage": 100,
        "FailureTolerancePercentage": 10
      }'
  fi

  # Esperar a que el StackSet termine de desplegarse
  wait_for_stackset_operation "$stackset_name"
}

# ──────────────────────────────────────────────────────────────────────────────
# FUNCIÓN: Esperar a que las operaciones del StackSet terminen
# ──────────────────────────────────────────────────────────────────────────────
wait_for_stackset_operation() {
  local stackset_name="$1"
  local max_wait=600  # 10 minutos máximo
  local elapsed=0
  local interval=15

  log_info "Esperando que el StackSet $stackset_name complete sus operaciones..."

  while [[ $elapsed -lt $max_wait ]]; do
    local operation_status
    operation_status=$(aws cloudformation list-stack-set-operations \
      --stack-set-name "$stackset_name" \
      --query 'Summaries[0].Status' \
      --output text 2>/dev/null || echo "UNKNOWN")

    case "$operation_status" in
      SUCCEEDED)
        log_success "StackSet $stackset_name: operación completada exitosamente"
        return 0
        ;;
      FAILED|STOPPED)
        log_error "StackSet $stackset_name: operación falló con estado $operation_status"
        # Mostrar errores específicos
        aws cloudformation list-stack-set-operation-results \
          --stack-set-name "$stackset_name" \
          --operation-id "$(aws cloudformation list-stack-set-operations \
            --stack-set-name "$stackset_name" \
            --query 'Summaries[0].OperationId' \
            --output text)" \
          --query 'Summaries[?Status==`FAILED`].[Account,Region,StatusReason]' \
          --output table
        return 1
        ;;
      RUNNING|QUEUED)
        echo -ne "\r${YELLOW}[WAIT]${NC}  StackSet $stackset_name en progreso... ${elapsed}s"
        sleep $interval
        elapsed=$((elapsed + interval))
        ;;
      UNKNOWN)
        # El StackSet acaba de crearse, esperar a que haya operaciones
        sleep $interval
        elapsed=$((elapsed + interval))
        ;;
    esac
  done

  log_error "Timeout esperando al StackSet $stackset_name (${max_wait}s)"
  return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# FUNCIÓN: Validar el resultado del despliegue
# ──────────────────────────────────────────────────────────────────────────────
validate_deployment() {
  log_section "✅ Validando Despliegue"

  local stacksets=(
    "brainmart-iam-roles"
    "brainmart-scp-policies"
    "brainmart-config-guardduty-cloudtrail"
  )

  local all_ok=true

  for stackset in "${stacksets[@]}"; do
    local status
    status=$(aws cloudformation describe-stack-set \
      --stack-set-name "$stackset" \
      --query 'StackSet.Status' \
      --output text 2>/dev/null || echo "NOT_FOUND")

    if [[ "$status" == "ACTIVE" ]]; then
      log_success "StackSet $stackset: ACTIVE ✓"
    else
      log_error "StackSet $stackset: $status ✗"
      all_ok=false
    fi
  done

  if [[ "$all_ok" == "true" ]]; then
    log_success "Todos los StackSets desplegados correctamente"
    return 0
  else
    log_error "Algunos StackSets fallaron. Revisar la consola de CloudFormation."
    return 1
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN — Ejecución principal
# ──────────────────────────────────────────────────────────────────────────────
main() {
  log_section "🚀 Brainmart - Deploy de CloudFormation StackSets"
  log_info "Organización: $ORG_ID"
  log_info "OU Raíz: $ROOT_OU_ID"
  log_info "Región Primaria: $PRIMARY_REGION"
  log_info "Región DR: $DR_REGION"
  [[ "$DRY_RUN" == "true" ]] && log_warning "MODO DRY-RUN: no se realizarán cambios reales"

  # PASO 1: Validar prerrequisitos
  validate_prerequisites

  # PASO 2: Habilitar trusted access en Organizations
  enable_trusted_access

  # PASO 3: Desplegar StackSet de IAM Roles (PRIMERO - prerequisito)
  log_section "📦 StackSet 1/3: IAM Roles"
  deploy_stackset \
    "brainmart-iam-roles" \
    "${SCRIPT_DIR}/iam-roles-stackset.yaml" \
    "[
      {\"ParameterKey\": \"SharedServicesAccountId\", \"ParameterValue\": \"${SHARED_SERVICES_ACCOUNT_ID}\"},
      {\"ParameterKey\": \"ProjectName\", \"ParameterValue\": \"brainmart\"},
      {\"ParameterKey\": \"ComplianceLevel\", \"ParameterValue\": \"FDA-21CFR11-GCP-ALCOA\"}
    ]" \
    "Roles IAM para que Terragrunt asuma permisos en cada cuenta Brainmart"

  # PASO 4: Desplegar StackSet de SCPs (gobernanza preventiva)
  log_section "📦 StackSet 2/3: Service Control Policies"
  deploy_stackset \
    "brainmart-scp-policies" \
    "${SCRIPT_DIR}/scp-policies-stackset.yaml" \
    "[
      {\"ParameterKey\": \"OrganizationId\", \"ParameterValue\": \"${ORG_ID}\"},
      {\"ParameterKey\": \"RootOUId\", \"ParameterValue\": \"${ROOT_OU_ID}\"},
      {\"ParameterKey\": \"ProjectName\", \"ParameterValue\": \"brainmart\"}
    ]" \
    "SCPs que previenen configuraciones inseguras en toda la organización"

  # PASO 5: Desplegar StackSet de Config Rules + GuardDuty + CloudTrail
  log_section "📦 StackSet 3/3: Config Rules + GuardDuty + CloudTrail"
  deploy_stackset \
    "brainmart-config-guardduty-cloudtrail" \
    "${SCRIPT_DIR}/config-rules-stackset.yaml" \
    "[
      {\"ParameterKey\": \"ProjectName\", \"ParameterValue\": \"brainmart\"},
      {\"ParameterKey\": \"ComplianceLevel\", \"ParameterValue\": \"FDA-21CFR11-GCP-ALCOA\"},
      {\"ParameterKey\": \"AuditLogsBucketName\", \"ParameterValue\": \"${AUDIT_BUCKET_NAME}\"},
      {\"ParameterKey\": \"CloudTrailLogGroupName\", \"ParameterValue\": \"/aws/cloudtrail/brainmart-org-trail\"},
      {\"ParameterKey\": \"SNSAlertTopicArn\", \"ParameterValue\": \"${SNS_ALERT_TOPIC_ARN}\"}
    ]" \
    "AWS Config Rules, GuardDuty y CloudTrail en toda la organización Brainmart"

  # PASO 6: Validar el despliegue
  log_section "🔍 Validación Final"
  validate_deployment

  log_section "🎉 Despliegue Completado"
  log_success "Capa 0 de gobernanza desplegada exitosamente"
  log_info ""
  log_info "Próximos pasos:"
  log_info "  1. Verificar en la consola de AWS Organizations que las SCPs están activas"
  log_info "  2. Verificar en AWS Config que las Rules están evaluando recursos"
  log_info "  3. Verificar en GuardDuty que el detector está activo"
  log_info "  4. Continuar con el despliegue de Capa 1 (Terragrunt):"
  log_info "     cd ../../infrastructure && terragrunt run-all init"
}

main "$@"
