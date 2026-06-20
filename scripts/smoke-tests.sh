#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# scripts/smoke-tests.sh — Validaciones post-deploy
# Verifica que la infraestructura desplegada cumple con los requisitos de seguridad
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

ENVIRONMENT="${1:-dev}"
while [[ $# -gt 0 ]]; do
  case $1 in --environment|-e) ENVIRONMENT="$2"; shift 2 ;; *) shift ;; esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASSED=0; FAILED=0

check() {
  local name="$1"; local cmd="$2"
  if eval "$cmd" &>/dev/null 2>&1; then
    echo -e "${GREEN}✅ PASS${NC} $name"; ((PASSED++))
  else
    echo -e "${RED}❌ FAIL${NC} $name"; ((FAILED++))
  fi
}

echo "🔍 Smoke Tests — Ambiente: ${ENVIRONMENT}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="us-east-1"
PREFIX="brainmart-${ENVIRONMENT}"

# ── Seguridad de S3 ──
check "S3 SPA bucket: block public access" \
  "aws s3api get-public-access-block --bucket ${PREFIX}-spa-assets --region ${REGION} | jq -e '.PublicAccessBlockConfiguration.BlockPublicAcls == true'"

check "S3 audit bucket: Object Lock habilitado" \
  "aws s3api get-object-lock-configuration --bucket ${PREFIX}-audit-logs --region ${REGION} | jq -e '.ObjectLockConfiguration.ObjectLockEnabled == \"Enabled\"'"

# ── RDS ──
check "RDS: cifrado habilitado" \
  "aws rds describe-db-instances --db-instance-identifier ${PREFIX}-rds-postgres --region ${REGION} | jq -e '.DBInstances[0].StorageEncrypted == true'"

check "RDS: deletion protection" \
  "[[ '${ENVIRONMENT}' != 'prod' ]] || aws rds describe-db-instances --db-instance-identifier ${PREFIX}-rds-postgres --region ${REGION} | jq -e '.DBInstances[0].DeletionProtection == true'"

# ── KMS ──
check "KMS: rotación habilitada en CMK" \
  "KEY_ID=\$(aws kms list-aliases --region ${REGION} | jq -r '.Aliases[] | select(.AliasName==\"alias/${PREFIX}-rds\") | .TargetKeyId') && aws kms get-key-rotation-status --key-id \$KEY_ID --region ${REGION} | jq -e '.KeyRotationEnabled == true'"

# ── CloudTrail ──
check "CloudTrail: trail activo" \
  "aws cloudtrail describe-trails --region ${REGION} | jq -e '.trailList | length > 0'"

# ── GuardDuty ──
check "GuardDuty: detector habilitado" \
  "aws guardduty list-detectors --region ${REGION} | jq -e '.DetectorIds | length > 0'"

# ── ECS ──
check "ECS: servicio activo" \
  "aws ecs describe-services --cluster ${PREFIX}-ecs-cluster --services ${PREFIX}-patient-service --region ${REGION} | jq -e '.services[0].status == \"ACTIVE\"'"

# ── Resumen ──
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}PASSED: ${PASSED}${NC} | ${RED}FAILED: ${FAILED}${NC}"
[[ $FAILED -gt 0 ]] && { echo -e "${RED}❌ Smoke tests fallaron${NC}"; exit 1; }
echo -e "${GREEN}✅ Todos los smoke tests pasaron${NC}"
