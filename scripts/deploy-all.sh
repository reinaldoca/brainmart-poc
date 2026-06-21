#!/usr/bin/env bash
# ??????????????????????????????????????????????????????????????????????????????
# scripts/deploy-all.sh
# Despliegue completo de Brainmart con un solo comando
# ??????????????????????????????????????????????????????????????????????????????

set -euo pipefail

ENVIRONMENT="${1:-dev}"
DRY_RUN=false
REQUIRE_APPROVAL=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_section() { echo -e "\n${CYAN}?? $* ??${NC}\n"; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --environment|-e) ENVIRONMENT="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=true;     shift ;;
    --require-approval) REQUIRE_APPROVAL=true; shift ;;
    *) shift ;;
  esac
done

# ?? Verificar prerrequisitos ??
log_section "Verificando prerrequisitos"
for cmd in terraform terragrunt aws docker checkov conftest jq; do
  if command -v $cmd &>/dev/null; then
    log_success "$cmd: $(command $cmd --version 2>&1 | head -1)"
  else
    log_error "$cmd no esta? instalado"
    exit 1
  fi
done

# ?? Cargar variables de entorno ??
if [[ -f "${ROOT_DIR}/.env" ]]; then
  source "${ROOT_DIR}/.env"
  log_success "Variables de entorno cargadas desde .env"
else
  log_warn ".env no encontrado. Asegu?rate de tener las variables de entorno definidas."
fi

# ?? PASO 1: Desplegar StackSets (Capa 0) ??
# log_section "PASO 1/4: CloudFormation StackSets (Gobernanza)"
# if [[ "$DRY_RUN" == "true" ]]; then
#   log_info "[DRY-RUN] Se desplegari?an los StackSets de gobernanza"
# else
#   bash "${ROOT_DIR}/governance/cloudformation-stacksets/deploy-stacksets.sh"
# fi

# ?? PASO 2: Validar poli?ticas (Capa 2) ??
log_section "PASO 2/4: Policy-as-Code (Checkov + OPA)"
cd "${ROOT_DIR}/infrastructure"

if [[ "$DRY_RUN" == "true" ]]; then
  log_info "[DRY-RUN] Se ejecutari?an Checkov y OPA"
else
  log_info "Ejecutando Checkov..."
  mkdir -p checkov-results
  # NOTE: --skip-path flags are passed as CLI args (not config file) because
  # Checkov on Windows parses files BEFORE evaluating skip-path from yaml.
  # The env-level terragrunt.hcl files contain Terragrunt-specific HCL
  # (exclude block) that is not valid Terraform syntax.
  checkov \
    -d . \
    --external-checks-dir policy-as-code/checkov/custom_policies/ \
    --config-file policy-as-code/checkov/.checkov.yaml \
    --skip-path environments/dev/terragrunt.hcl \
    --skip-path environments/staging/terragrunt.hcl \
    --skip-path environments/prod/terragrunt.hcl \
    --output cli \
    --output junitxml \
    --output-file-path checkov-results
  log_success "Checkov: todos los checks pasaron"
fi

# ?? PASO 3: Terragrunt Init + Plan ??
log_section "PASO 3/4: Terragrunt Plan"
cd "${ROOT_DIR}/infrastructure/environments/${ENVIRONMENT}"

if [[ "$DRY_RUN" == "true" ]]; then
  log_info "[DRY-RUN] Se ejecutari?a: terragrunt run --all plan"
else
  log_info "Inicializando Terraform..."
  terragrunt run --all --non-interactive init

  log_info "Generando plan..."
  terragrunt run --all --non-interactive plan | tee /tmp/terraform-plan.txt

  if [[ "$REQUIRE_APPROVAL" == "true" ]]; then
    echo ""
    log_warn "?Aprobar el deploy a ${ENVIRONMENT}? (yes/no)"
    read -r APPROVAL
    [[ "$APPROVAL" != "yes" ]] && { log_warn "Deploy cancelado."; exit 0; }
  fi
fi

# ?? PASO 4: Terragrunt Apply ??
log_section "PASO 4/4: Terragrunt Apply"
if [[ "$DRY_RUN" == "true" ]]; then
  log_info "[DRY-RUN] Se ejecutari?a: terragrunt run --all apply"
else
  terragrunt run --all --non-interactive apply -auto-approve
  log_success "Deploy a ${ENVIRONMENT} completado"

  # Smoke tests post-deploy
  bash "${ROOT_DIR}/scripts/smoke-tests.sh" --environment "${ENVIRONMENT}"
fi

log_section "? Deploy completado"
log_success "Ambiente: ${ENVIRONMENT}"
log_success "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
