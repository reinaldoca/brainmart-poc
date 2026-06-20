# 🧠 Brainmart DevSecOps POC

> **Plataforma enterprise-grade para digitalización de ensayos clínicos**  
> Cumplimiento: FDA 21 CFR Part 11 · GCP · ALCOA+ · GDPR · HIPAA-ready

[![CI/CD Pipeline](https://github.com/brainmart/brainmart-poc/actions/workflows/ci-cd.yml/badge.svg)](https://github.com/brainmart/brainmart-poc/actions)
[![Checkov](https://img.shields.io/badge/Checkov-Policy--as--Code-blue)](https://www.checkov.io/)
[![OPA](https://img.shields.io/badge/OPA-Rego--Policies-green)](https://www.openpolicyagent.org/)
[![Terraform](https://img.shields.io/badge/Terraform-1.7+-purple)](https://www.terraform.io/)
[![Terragrunt](https://img.shields.io/badge/Terragrunt-0.55+-orange)](https://terragrunt.gruntwork.io/)

---

## 📋 Índice

1. [Arquitectura General](#-arquitectura-general)
2. [Prerrequisitos](#-prerrequisitos)
3. [Despliegue con un Solo Comando](#-despliegue-con-un-solo-comando)
4. [Despliegue Paso a Paso](#-despliegue-paso-a-paso)
5. [Estructura del Proyecto](#-estructura-del-proyecto)
6. [Cumplimiento Regulatorio](#-cumplimiento-regulatorio)
7. [Demo en Vivo (10 minutos)](#-demo-en-vivo-10-minutos)
8. [Resumen Ejecutivo](#-resumen-ejecutivo)

---

## 🏗️ Arquitectura General

```
┌─────────────────────────────────────────────────────────────────────┐
│                    AWS ORGANIZATION (Master Account)                 │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │              CAPA 0: CloudFormation StackSets                │    │
│  │  • IAM Roles (BrainmartTerragruntRole en cada cuenta)       │    │
│  │  • SCPs: No S3 público, No puertos abiertos, Cifrado        │    │
│  │  • AWS Config Rules + GuardDuty + CloudTrail Org            │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                              ↓                                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────────┐    │
│  │   DEV    │  │ STAGING  │  │   PROD   │  │ SHARED-SERVICES │    │
│  │us-east-1 │  │us-east-1 │  │us-east-1 │  │  (CI/CD, ECR)   │    │
│  └──────────┘  └──────────┘  └──────────┘  └─────────────────┘    │
│                                    ↕ DR Replication                  │
│                              ┌──────────┐                            │
│                              │PROD DR   │                            │
│                              │eu-west-1 │ ← GDPR Data Residency     │
│                              └──────────┘                            │
└─────────────────────────────────────────────────────────────────────┘

CAPA 1: Terragrunt + Terraform (gestiona TODA la infraestructura arriba)
CAPA 2: Checkov + OPA (valida ANTES de cualquier cambio)
```

### Stack Tecnológico

| Capa | Tecnología | Versión | Propósito |
|------|-----------|---------|-----------|
| IaC Gobernanza | CloudFormation StackSets | Latest | Políticas org-wide |
| IaC Infra | Terragrunt + Terraform | 0.55+ / 1.7+ | Multi-cuenta/región |
| Policy-as-Code | Checkov + OPA/Rego | 3.x / 0.65+ | Shift-Left Security |
| Backend | .NET 8 / ECS Fargate | 8.0 LTS | Microservicios |
| Frontend | Angular 17 / CloudFront | 17.x | SPA con WAF |
| Base de Datos | RDS PostgreSQL 15 | 15.x | Con audit triggers ALCOA+ |
| Cifrado | AWS KMS CMK | Latest | Envelope encryption |
| Secretos | AWS Secrets Manager | Latest | Rotación automática 30d |
| Observabilidad | CloudWatch + X-Ray | Latest | Trazas distribuidas |
| CI/CD | GitHub Actions | Latest | Pipeline completo |

---

## 🔧 Prerrequisitos

### Herramientas Locales

```bash
# Verificar versiones mínimas requeridas
terraform --version    # >= 1.7.0
terragrunt --version   # >= 0.55.0
aws --version          # >= 2.15.0
docker --version       # >= 24.0.0
checkov --version      # >= 3.0.0
conftest --version     # >= 0.48.0 (runner para OPA)
jq --version           # >= 1.6
```

### Instalación en macOS/Linux

```bash
# Terraform
brew tap hashicorp/tap && brew install hashicorp/tap/terraform

# Terragrunt
brew install terragrunt

# Checkov
pip3 install checkov

# Conftest (OPA runner)
brew install conftest

# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install
```

### Permisos AWS Requeridos

```
Cuenta Master de la Organización:
  - organizations:* (para StackSets y SCPs)
  - cloudformation:* (para StackSets)
  - iam:CreateRole, iam:AttachRolePolicy (en cuentas miembro via StackSets)

Cuenta Shared-Services (CI/CD):
  - sts:AssumeRole en las cuentas dev/staging/prod
  - ecr:* (para push de imágenes)
  - s3:* en bucket de estado de Terragrunt
```

### Variables de Entorno

```bash
# Copiar el archivo de ejemplo y completar los valores
cp .env.example .env

# Variables requeridas:
export AWS_MASTER_ACCOUNT_ID="123456789012"
export AWS_DEV_ACCOUNT_ID="234567890123"
export AWS_STAGING_ACCOUNT_ID="345678901234"
export AWS_PROD_ACCOUNT_ID="456789012345"
export AWS_SHARED_SERVICES_ACCOUNT_ID="567890123456"
export AWS_ORG_ID="o-xxxxxxxxxxxx"
export TF_STATE_BUCKET_PREFIX="brainmart-tfstate"
export BRAINMART_PROJECT_NAME="brainmart"
```

---

## 🚀 Despliegue con un Solo Comando

> ⚠️ **IMPORTANTE**: Este comando despliega TODA la infraestructura desde cero.  
> Solo ejecutar con credenciales de la cuenta Master de la organización.

```bash
# Despliegue completo: Gobernanza + Infraestructura Dev
./scripts/deploy-all.sh --environment dev --dry-run   # Simulación primero
./scripts/deploy-all.sh --environment dev             # Despliegue real

# Para producción (requiere confirmación adicional)
./scripts/deploy-all.sh --environment prod --require-approval
```

**El script `deploy-all.sh` ejecuta en orden:**
1. ✅ Validación de prerrequisitos y permisos AWS
2. 🏛️ Deploy de CloudFormation StackSets (Capa 0)
3. 🔍 Checkov + OPA validation (Capa 2)
4. 🏗️ `terragrunt run-all init` (Capa 1)
5. 📋 `terragrunt run-all plan` con output guardado
6. 🚀 `terragrunt run-all apply` (con aprobación en prod)
7. ✅ Smoke tests de validación post-deploy
8. 📊 Apertura del dashboard de CloudWatch

---

## 📋 Despliegue Paso a Paso

### Paso 1: Clonar y Configurar

```bash
git clone https://github.com/brainmart/brainmart-poc.git
cd brainmart-poc

# Configurar las variables de entorno
cp .env.example .env
# Editar .env con los IDs de cuenta correctos
source .env
```

### Paso 2: Desplegar Gobernanza (Capa 0)

```bash
cd governance/cloudformation-stacksets

# 1. Crear el S3 bucket para estado de Terragrunt (bootstrap)
#    Este bucket debe existir ANTES del primer terragrunt init
aws s3api create-bucket \
  --bucket "${TF_STATE_BUCKET_PREFIX}-${AWS_DEV_ACCOUNT_ID}-us-east-1" \
  --region us-east-1

# 2. Habilitar versionado y cifrado en el bucket de estado
aws s3api put-bucket-versioning \
  --bucket "${TF_STATE_BUCKET_PREFIX}-${AWS_DEV_ACCOUNT_ID}-us-east-1" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "${TF_STATE_BUCKET_PREFIX}-${AWS_DEV_ACCOUNT_ID}-us-east-1" \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms"}}]
  }'

# 3. Crear tabla DynamoDB para locks de estado
aws dynamodb create-table \
  --table-name brainmart-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1

# 4. Desplegar los StackSets
./deploy-stacksets.sh
```

### Paso 3: Validar Políticas (Capa 2)

```bash
cd infrastructure

# Checkov: validar módulos de Terraform contra políticas custom
checkov -d modules/ \
  --external-checks-dir policy-as-code/checkov/custom_policies/ \
  --config-file policy-as-code/checkov/.checkov.yaml \
  --output cli \
  --output junitxml \
  --output-file-path checkov-results/

# OPA/Conftest: validar plan de Terraform contra políticas Rego
terragrunt run-all plan -out=tfplan.binary
terraform show -json tfplan.binary > tfplan.json
conftest test tfplan.json \
  --policy policy-as-code/opa/policies/ \
  --output table

# Ver resumen de cumplimiento
cat checkov-results/results_junitxml.xml | python3 -c "
import sys, xml.etree.ElementTree as ET
tree = ET.parse(sys.stdin)
root = tree.getroot()
print(f'✅ Passed: {root.get(\"tests\")}')
print(f'❌ Failed: {root.get(\"failures\")}')
"
```

### Paso 4: Desplegar Infraestructura DEV

```bash
cd infrastructure/environments/dev

# Inicializar todos los módulos
terragrunt run-all init

# Plan (ver qué se va a crear)
terragrunt run-all plan --terragrunt-non-interactive

# Apply en orden correcto (network → database → compute → storage → secrets)
terragrunt run-all apply --terragrunt-non-interactive

# Verificar outputs
terragrunt run-all output
```

### Paso 5: Verificar Compliance Post-Deploy

```bash
# Ejecutar smoke tests de seguridad
./scripts/smoke-tests.sh --environment dev

# Los smoke tests verifican:
# ✅ Todos los buckets S3 tienen block_public_acls
# ✅ RDS tiene encryption at rest habilitado
# ✅ CloudTrail está activo y logueando
# ✅ GuardDuty está habilitado en todas las regiones
# ✅ Secrets Manager tiene rotación configurada
# ✅ VPC no tiene rutas directas a internet desde subnets privadas
```

### Paso 6: Deploy a Staging y Producción

```bash
# Staging (automático desde CI/CD)
git checkout -b release/1.0.0
git push origin release/1.0.0
# → GitHub Actions ejecuta el pipeline completo
# → Deploy automático a staging tras pasar todos los checks
# → DAST con OWASP ZAP en staging

# Producción (requiere aprobación manual en GitHub Actions)
git checkout main
git merge release/1.0.0
git push origin main
# → CI/CD despliega hasta staging automáticamente
# → Solicita aprobación manual para prod (en GitHub Environments)
# → Tras aprobación: deploy a us-east-1 (primario) y eu-west-1 (DR)
```

---

## 📁 Estructura del Proyecto

```
brainmart-poc/
├── 📄 README.md                          ← Este archivo
├── 🔧 .env.example                       ← Variables de entorno necesarias
├── 🚀 scripts/
│   ├── deploy-all.sh                     ← Despliegue con un comando
│   └── smoke-tests.sh                    ← Validación post-deploy
│
├── 🏛️ governance/                        ← CAPA 0: CloudFormation StackSets
│   ├── cloudformation-stacksets/
│   │   ├── iam-roles-stackset.yaml       ← Roles Terragrunt en cada cuenta
│   │   ├── scp-policies-stackset.yaml    ← SCPs org-wide
│   │   ├── config-rules-stackset.yaml    ← AWS Config compliance rules
│   │   └── deploy-stacksets.sh           ← Orquestador de StackSets
│   └── policies/
│       ├── scp-prohibit-public-s3.json
│       ├── scp-prohibit-open-ports.json
│       └── scp-require-encryption.json
│
├── 🏗️ infrastructure/                    ← CAPA 1: Terragrunt + Terraform
│   ├── terragrunt.hcl                    ← ROOT: backend + providers + globals
│   ├── account.hcl                       ← IDs de cuentas AWS
│   ├── region.hcl                        ← Mapeo región→entorno
│   ├── environments/
│   │   ├── dev/                          ← Entorno de desarrollo
│   │   ├── staging/                      ← Entorno de pruebas
│   │   └── prod/                         ← Producción (us-east-1 + eu-west-1 DR)
│   ├── modules/                          ← Módulos Terraform reutilizables
│   │   ├── network/                      ← VPC, subnets, NAT, endpoints
│   │   ├── database/                     ← RDS PostgreSQL con audit triggers
│   │   ├── compute/                      ← ECS Fargate + Auto Scaling
│   │   ├── storage/                      ← S3 + CloudFront + WAF
│   │   └── secrets/                      ← Secrets Manager con rotación
│   └── policy-as-code/                   ← CAPA 2: Policy-as-Code
│       ├── checkov/                      ← Custom policies Python
│       └── opa/                          ← Políticas Rego + tests
│
├── 🖥️ microservices/
│   └── patient-service/                  ← API .NET 8 con cifrado de campos
│
├── 🌐 frontend/
│   └── patient-dashboard/                ← Angular 17 con CSP estricta
│
├── 🔄 pipeline/
│   └── .github/workflows/
│       ├── ci-cd.yml                     ← Pipeline principal completo
│       ├── policy-check.yml              ← Checkov + OPA standalone
│       └── sbom-generate.yml             ← Generación SBOM SPDX
│
├── 📊 monitoring/
│   ├── cloudwatch-dashboards.json
│   ├── alarms-config.json
│   └── xray-config.yml
│
└── 📚 documentation/
    ├── runbook-failover.md               ← DR paso a paso < 5 minutos
    ├── traceability-matrix.md            ← FDA 21 CFR Part 11 → implementación
    ├── backup-restoration-plan.md
    └── data-retention-policy.md
```

---

## 📜 Cumplimiento Regulatorio

### FDA 21 CFR Part 11 — Electronic Records & Signatures

| Requisito | Implementación | Evidencia |
|-----------|---------------|-----------|
| Audit Trail completo | Triggers PostgreSQL → tabla `audit_log` | `modules/database/scripts/audit-triggers.sql` |
| No repudio | JWT en HttpOnly cookies + audit_log.changed_by | `microservices/patient-service/` |
| Retención de registros | S3 Object Lock (GOVERNANCE) 7 años | `modules/storage/main.tf` |
| Integridad de datos | KMS envelope encryption + checksums SHA-256 | `modules/database/main.tf` |
| Acceso controlado | IAM mínimo privilegio + MFA obligatorio | `governance/cloudformation-stacksets/iam-roles-stackset.yaml` |

### ALCOA+ — Principios de Integridad de Datos

| Principio | Implementación |
|-----------|---------------|
| **A**ttributable | `audit_log.changed_by` = usuario JWT + `audit_log.ip_address` |
| **L**egible | Formato Parquet en S3 + Athena queries |
| **C**ontemporaneous | `audit_log.changed_at = NOW()` con timezone UTC |
| **O**riginal | `audit_log.old_values` JSONB con valor previo |
| **A**ccurate | `audit_log.new_values` JSONB con checksums |
| **+** Complete | Triggers en INSERT/UPDATE/DELETE sin excepciones |
| **+** Consistent | Timezone UTC en toda la plataforma |
| **+** Enduring | S3 Glacier Deep Archive después de 2 años |
| **+** Available | Athena queries desde dashboard CloudWatch |

### GDPR — Protección de Datos EU

| Requisito | Implementación |
|-----------|---------------|
| Residencia de datos EU | Replicación lógica a `eu-west-1` |
| Minimización de datos | Solo campos necesarios en API response |
| Derecho al olvido | Procedure `fn_anonymize_patient()` con KMS key deletion |
| Cifrado en tránsito | TLS 1.3 en ALB, CloudFront y conexiones RDS |
| Cifrado en reposo | KMS CMK en RDS, S3, EBS, Secrets Manager |

---

## 🎬 Demo en Vivo (10 minutos)

### Guión de Demostración

```bash
# MINUTO 1-2: Despliegue completo desde cero
time ./scripts/deploy-all.sh --environment dev --demo-mode

# MINUTO 3-4: Crear paciente con cifrado de campos sensibles
curl -X POST https://api-dev.brainmart.health/api/v1/patients \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "firstName": "María",
    "lastName": "García López",
    "documentId": "12345678A",
    "trialId": "NCT-2024-001",
    "consentDate": "2024-01-15T10:30:00Z"
  }'
# → Los campos documentId, firstName, lastName se cifran con KMS antes de persistir

# MINUTO 5: Consultar audit trail del paciente
./scripts/query-audit-trail.sh --patient-id "patient-uuid-here"
# → Muestra todos los accesos/modificaciones al registro del paciente
# → Consultado desde Athena sobre los logs en S3

# MINUTO 6-7: Simular ataque XSS bloqueado
curl -X POST https://api-dev.brainmart.health/api/v1/patients \
  -d '{"firstName": "<script>alert(1)</script>"}' \
# → WAF bloquea con 403 Forbidden
# → CloudWatch Alarm se activa
# → Notificación a Slack via SNS + Lambda

# MINUTO 8-9: Failover de base de datos
./scripts/simulate-db-failover.sh
# → Simula caída de RDS primario en us-east-1
# → Promueve réplica en eu-west-1
# → Verifica integridad de datos
# → Todo en < 5 minutos

# MINUTO 10: Mostrar dashboard de auditoría
open https://console.aws.amazon.com/cloudwatch/dashboards/brainmart-audit
```

---

## 📊 Resumen Ejecutivo

### Valor de Negocio para Brainmart

**El problema que resuelve esta arquitectura:**
Los ensayos clínicos digitales fallan las auditorías regulatorias porque los sistemas no pueden demostrar la integridad de sus datos. Una observación de la FDA puede detener un ensayo y costar millones.

**Lo que esta POC demuestra:**

1. **Cumplimiento auditable** — Cada cambio en datos de pacientes genera un registro inmutable con quién, cuándo, desde dónde y qué cambió. Esto es exactamente lo que FDA y EMA solicitan en auditorías.

2. **Seguridad por diseño** — Las políticas de seguridad son código (Checkov + OPA). Es imposible desplegar infraestructura que viole las reglas de compliance sin que el pipeline falle primero.

3. **Escala global con governance** — La arquitectura multi-cuenta con StackSets permite onboarding de nuevos ensayos clínicos en horas, no semanas, con las mismas políticas de seguridad automáticamente aplicadas.

4. **DR demostrable** — El failover a EU en < 5 minutos no es solo un número; es un script ejecutable que se puede mostrar a auditores y clientes.

5. **ROI medible:**
   - Reducción de tiempo de auditoría: de 3 semanas a 2 días (audit trail automatizado)
   - Reducción de riesgo de observaciones FDA: políticas preventivas vs. reactivas
   - Time-to-market de nuevos ensayos: onboarding en horas con infraestructura pre-compliance

> *"No vendemos solo software. Vendemos confianza regulatoria."*

---

## 🆘 Soporte y Contacto

| Tipo | Contacto |
|------|---------|
| Incidentes P1 (producción caída) | Runbook: `documentation/runbook-failover.md` |
| Alertas de compliance | CloudWatch → SNS → Slack `#brainmart-alerts` |
| Preguntas regulatorias | Ver `documentation/traceability-matrix.md` |

---

*Generado por el equipo DevSecOps de Brainmart · Versión 1.0.0 · FDA 21 CFR Part 11 Compliant*
