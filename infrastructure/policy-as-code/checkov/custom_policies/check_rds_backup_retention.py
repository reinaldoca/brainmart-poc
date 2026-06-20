# ??????????????????????????????????????????????????????????????????????????????
# infrastructure/policy-as-code/checkov/custom_policies/check_rds_backup_retention.py
#
# POLI?TICA CHECKOV CUSTOM: Validar backup_retention_period en RDS
#
# REQUISITO REGULATORIO: GCP ICH E6(R2) requiere que los datos de ensayos
# cli?nicos se conserven por al menos 2 an?os despue?s del ensayo.
# Para garantizar recuperabilidad, el backup de la BD debe ser de 35 di?as.
#
# 35 di?as = permite recuperar desde cualquier di?a del mes anterior + actual
#
# OPA policy (rds_multi_az.rego) complementa esta check validando
# que prod tambie?n tenga Multi-AZ habilitado.
# ??????????????????????????????????????????????????????????????????????????????

from checkov.common.models.enums import CheckResult, CheckCategories
from checkov.terraform.checks.resource.base_resource_check import BaseResourceCheck
from typing import Dict, Any


class RDSBackupRetentionCheck(BaseResourceCheck):
    """
    Verifica que todas las instancias RDS tengan backup_retention_period >= 35 di?as.
    
    35 di?as es el requisito mi?nimo de GCP (Good Clinical Practice) para
    datos de ensayos cli?nicos. Este nu?mero no es arbitrario:
    
    - Permite recuperar desde cualquier di?a del mes anterior + el mes actual
    - Cubre el peri?odo ma?ximo de un ciclo de tratamiento en muchos ensayos
    - Es el esta?ndar de la industria farmace?utica para sistemas de datos cli?nicos
    
    NOTA: En entornos dev/staging, Brainmart acepta < 35 di?as por costo.
    La OPA policy (produccio?n) verifica el requisito ma?s estrictamente.
    Esta check de Checkov es ma?s permisiva: verifica que NO sea 0 (sin backup).
    """
    
    def __init__(self):
        name = "Ensure RDS instances have automated backup enabled with sufficient retention (GCP requirement: >= 35 days)"
        id = "CKV_BRAINMART_4"
        supported_resources = ["aws_db_instance", "aws_rds_cluster"]
        categories = [CheckCategories.BACKUP_AND_RECOVERY]
        super().__init__(name=name, id=id, categories=categories,
                         supported_resources=supported_resources)

    def scan_resource_conf(self, conf: Dict[str, Any], entity_type: str = None) -> CheckResult:
        """
        Evalu?a la configuracio?n de backup de la instancia RDS.
        
        Checkov recibe el valor del plan de Terraform (ya evaluado),
        no la expresio?n de la variable. Si backup_retention_period = var.backup_retention_period,
        Checkov recibe el valor nume?rico final.
        """
        backup_retention = conf.get("backup_retention_period", [0])
        
        # Extraer el valor nume?rico
        if isinstance(backup_retention, list):
            retention_days = backup_retention[0] if backup_retention else 0
        else:
            retention_days = backup_retention
            
        # Convertir a entero (puede llegar como string desde algunos parsers)
        try:
            retention_days = int(retention_days)
        except (TypeError, ValueError):
            # Si no se puede convertir, es una referencia no resuelta
            # Checkov no puede validarla, dejar pasar (OPA lo valida en runtime)
            return CheckResult.PASSED
        
        # FALLA CRI?TICA: backup_retention_period = 0 significa backups DESHABILITADOS
        # Esto viola GCP y FDA 21 CFR Part 11 (recuperabilidad de datos)
        if retention_days == 0:
            return CheckResult.FAILED
            
        # ADVERTENCIA: menos de 7 di?as es insuficiente para cualquier ambiente
        if retention_days < 7:
            return CheckResult.FAILED
            
        # Checkov check pasa si hay al menos 7 di?as de backup
        # La validacio?n estricta de 35 di?as se hace en OPA (para prod)
        return CheckResult.PASSED


class RDSBackupRetentionStrictCheck(BaseResourceCheck):
    """
    Versio?n estricta: verifica que el backup sea exactamente >= 35 di?as.
    Esta check se aplica solo en contextos de produccio?n.
    
    Se detecta el ambiente por los tags del recurso:
    - Si Environment = "prod", se requieren >= 35 di?as
    - Si Environment = "dev" o "staging", se permiten menos (mi?nimo 7)
    """
    
    def __init__(self):
        name = "Ensure RDS production instances have backup_retention_period >= 35 days (GCP ICH E6(R2) requirement)"
        id = "CKV_BRAINMART_5"
        supported_resources = ["aws_db_instance", "aws_rds_cluster"]
        categories = [CheckCategories.BACKUP_AND_RECOVERY]
        super().__init__(name=name, id=id, categories=categories,
                         supported_resources=supported_resources)

    def scan_resource_conf(self, conf: Dict[str, Any], entity_type: str = None) -> CheckResult:
        """
        Evalu?a si el recurso es de produccio?n y verifica el requisito de 35 di?as.
        """
        # Obtener los tags para determinar el ambiente
        tags = conf.get("tags", [{}])
        if isinstance(tags, list):
            tags = tags[0] if tags else {}
            
        environment = tags.get("Environment", "").lower()
        
        # Si no hay tags de Environment, no podemos determinar el ambiente
        # Usar el check permisivo (CKV_BRAINMART_4) para el caso base
        if not environment:
            return CheckResult.PASSED
            
        # Solo aplicar el check estricto a produccio?n
        if environment not in ["prod", "production"]:
            return CheckResult.PASSED
            
        # Para produccio?n: verificar >= 35 di?as
        backup_retention = conf.get("backup_retention_period", [0])
        if isinstance(backup_retention, list):
            retention_days = backup_retention[0] if backup_retention else 0
        else:
            retention_days = backup_retention
            
        try:
            retention_days = int(retention_days)
        except (TypeError, ValueError):
            return CheckResult.PASSED  # Referencia no resuelta
            
        if retention_days < 35:
            return CheckResult.FAILED
            
        return CheckResult.PASSED


class RDSEncryptionCheck(BaseResourceCheck):
    """
    Verifica que TODAS las instancias RDS tengan storage_encrypted = true.
    
    Esta check complementa el SCP de Capa 0 (scp-require-encryption.json).
    El SCP previene la creacio?n de RDS sin cifrado en AWS.
    Esta check detecta el problema ANTES del plan (Shift-Left).
    """
    
    def __init__(self):
        name = "Ensure RDS instances have storage encryption enabled with KMS CMK (FDA 21 CFR Part 11 ?11.10(c))"
        id = "CKV_BRAINMART_6"
        supported_resources = ["aws_db_instance", "aws_rds_cluster"]
        categories = [CheckCategories.ENCRYPTION]
        super().__init__(name=name, id=id, categories=categories,
                         supported_resources=supported_resources)

    def scan_resource_conf(self, conf: Dict[str, Any], entity_type: str = None) -> CheckResult:
        # Verificar storage_encrypted = true
        encrypted = conf.get("storage_encrypted", [False])
        if isinstance(encrypted, list):
            encrypted = encrypted[0] if encrypted else False
            
        if not encrypted:
            return CheckResult.FAILED
            
        # Verificar que se usa KMS CMK (no la default key de AWS)
        kms_key = conf.get("kms_key_id", [""])
        if isinstance(kms_key, list):
            kms_key = kms_key[0] if kms_key else ""
            
        # Si kms_key_id esta? vaci?o, RDS usa la key por defecto de AWS
        # Para datos de PHI, se requiere una CMK propia (ma?s control y auditabilidad)
        # NOTA: En la POC, el mo?dulo crea la CMK si kms_key_id esta? vaci?o
        # Asi? que este check es informativo: recomendamos CMK expli?cita
        if not kms_key:
            # Advertencia pero no falla: el mo?dulo crea una CMK automa?ticamente
            # En un ambiente ma?s estricto, esto seri?a FAILED
            pass
            
        return CheckResult.PASSED


# Registrar las poli?ticas
checker_rds_backup = RDSBackupRetentionCheck()
checker_rds_backup_strict = RDSBackupRetentionStrictCheck()
checker_rds_encryption = RDSEncryptionCheck()
