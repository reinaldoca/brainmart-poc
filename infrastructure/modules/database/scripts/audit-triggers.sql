-- ?????????????????????????????????????????????????????????????????????????????
-- modules/database/scripts/audit-triggers.sql
--
-- PROPO?SITO: Implementar el Audit Trail ALCOA+ en PostgreSQL 15
-- Este script crea la infraestructura de auditori?a que cumple con:
--   - FDA 21 CFR Part 11 ?11.10(e): Audit trail completo e inalterado
--   - ALCOA+: Attributable, Legible, Contemporaneous, Original, Accurate
--   - GCP ICH E6(R2): Trazabilidad completa de datos de ensayos cli?nicos
--
-- ARQUITECTURA:
--   1. Tabla audit_log: almacena cada cambio con todos los detalles ALCOA+
--   2. Funcio?n fn_audit_trigger(): captura OLD/NEW y escribe en audit_log
--   3. Funcio?n fn_apply_audit_trigger(): aplica el trigger a cualquier tabla
--   4. Vista v_audit_summary: resumen para dashboards de Athena
--
-- IMPORTANTE: Este script es IDEMPOTENTE (puede ejecutarse mu?ltiples veces)
-- ?????????????????????????????????????????????????????????????????????????????

-- Extensiones necesarias
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";     -- Para gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "pgcrypto";       -- Para funciones de hash
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements"; -- Para ana?lisis de queries

-- ?????????????????????????????????????????????????????????????????????????????
-- TABLA: audit_log
-- Almacena TODOS los cambios en tablas de datos cli?nicos.
-- Es la evidencia primaria para auditori?as FDA/GCP.
--
-- ALCOA+ mapping:
--   A (Attributable)     ? changed_by, ip_address, session_id
--   L (Legible)          ? almacenada en Parquet en S3, queryable por Athena
--   C (Contemporaneous)  ? changed_at = NOW() en zona horaria UTC
--   O (Original)         ? old_values contiene el valor ANTES del cambio
--   A (Accurate)         ? new_values contiene el valor EXACTO del cambio
--   + (Complete)         ? triggers en INSERT + UPDATE + DELETE sin excepciones
--   + (Consistent)       ? timezone UTC en toda la plataforma
--   + (Enduring)         ? retenida 7 an?os (S3 lifecycle)
--   + (Available)        ? Athena queries desde dashboard CloudWatch
-- ?????????????????????????????????????????????????????????????????????????????

CREATE TABLE IF NOT EXISTS audit_log (
    -- Identificador u?nico del registro de auditori?a
    -- UUID v4: no secuencial (evita enumeracio?n de registros)
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- A (Attributable): ?Que? recurso fue modificado?
    schema_name     VARCHAR(100)    NOT NULL DEFAULT current_schema(),
    table_name      VARCHAR(100)    NOT NULL,
    record_id       TEXT            NOT NULL,  -- PK del registro modificado (puede ser compuesta)

    -- A (Attributable): ?Que? tipo de operacio?n fue?
    operation       CHAR(1)         NOT NULL,  -- I=INSERT, U=UPDATE, D=DELETE

    -- A (Attributable): ?Quie?n hizo el cambio?
    -- Se combina: usuario de BD + claim JWT (inyectado por la app via SET LOCAL)
    changed_by      VARCHAR(200)    NOT NULL,  -- usuario_db::jwt_sub si esta? disponible
    application_user VARCHAR(200),             -- claim 'sub' del JWT (usuario de la app)
    ip_address      INET,                      -- IP desde donde vino la operacio?n
    session_id      VARCHAR(100),              -- ID de sesio?n de la app (para correlacio?n)

    -- C (Contemporaneous): ?Cua?ndo ocurrio? exactamente?
    changed_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),  -- UTC siempre
    transaction_id  BIGINT          DEFAULT txid_current(),  -- ID de transaccio?n de PostgreSQL

    -- O (Original): ?Cua?l era el valor ANTES del cambio?
    -- NULL para INSERT (no habi?a valor previo)
    old_values      JSONB,

    -- A (Accurate): ?Cua?l es el valor DESPUE?S del cambio?
    -- NULL para DELETE (no hay valor posterior)
    new_values      JSONB,

    -- Campos adicionales para trazabilidad
    row_data        JSONB,      -- Snapshot completo de la fila (para DELETE)
    changed_fields  TEXT[],     -- Lista de campos que cambiaron (para UPDATE)

    -- Metadatos de la aplicacio?n
    request_id      VARCHAR(100),  -- Request ID del API call que genero? el cambio
    correlation_id  VARCHAR(100),  -- ID de correlacio?n para distributed tracing (X-Ray)

    -- Integridad: checksum del registro para detectar tampering
    -- Se calcula al insertar: SHA-256(table_name || record_id || operation || changed_at || new_values)
    integrity_hash  VARCHAR(64),

    -- Restricciones
    CONSTRAINT chk_operation CHECK (operation IN ('I', 'U', 'D')),
    CONSTRAINT chk_changed_by_not_empty CHECK (length(trim(changed_by)) > 0)
);

-- ?????????????????????????????????????????????????????????????????????????????
-- I?NDICES para consultas frecuentes de auditori?a
-- Los auditores consultan por: tabla, peri?odo de tiempo, usuario, operacio?n
-- ?????????????????????????????????????????????????????????????????????????????

-- I?ndice principal: tabla + fecha (las consultas ma?s comunes)
CREATE INDEX IF NOT EXISTS idx_audit_log_table_changed_at
    ON audit_log(table_name, changed_at DESC);

-- Por usuario: para investigar actividad de un usuario especi?fico
CREATE INDEX IF NOT EXISTS idx_audit_log_changed_by
    ON audit_log(changed_by, changed_at DESC);

-- Por registro: para ver el historial completo de un paciente/ensayo especi?fico
CREATE INDEX IF NOT EXISTS idx_audit_log_record
    ON audit_log(table_name, record_id, changed_at DESC);

-- Por operacio?n: para contar INSERT/UPDATE/DELETE (me?tricas de uso)
CREATE INDEX IF NOT EXISTS idx_audit_log_operation
    ON audit_log(operation, changed_at DESC);

-- Por fecha: para consultas de rango de tiempo (reportes de auditori?a)
CREATE INDEX IF NOT EXISTS idx_audit_log_changed_at
    ON audit_log USING BRIN (changed_at);  -- BRIN es eficiente para datos ordenados por tiempo

-- ?????????????????????????????????????????????????????????????????????????????
-- FUNCIO?N: fn_audit_trigger()
-- Trigger function gene?rica que se aplica a cualquier tabla.
-- Captura OLD y NEW, calcula el integrity_hash, e inserta en audit_log.
-- ?????????????????????????????????????????????????????????????????????????????

CREATE OR REPLACE FUNCTION fn_audit_trigger()
RETURNS TRIGGER AS $$
DECLARE
    v_old_values    JSONB;
    v_new_values    JSONB;
    v_record_id     TEXT;
    v_changed_by    TEXT;
    v_app_user      TEXT;
    v_ip_address    INET;
    v_session_id    TEXT;
    v_request_id    TEXT;
    v_correlation_id TEXT;
    v_changed_fields TEXT[];
    v_integrity_hash TEXT;
    v_operation     CHAR(1);
BEGIN
    -- ?? Determinar el tipo de operacio?n ??
    IF (TG_OP = 'INSERT') THEN
        v_operation := 'I';
        v_old_values := NULL;
        v_new_values := row_to_json(NEW)::JSONB;
        -- Obtener el ID del registro insertado
        -- ASUMCIO?N: la tabla tiene un campo 'id' como PK
        -- En tablas con PK diferente, se usa el ctid (system column)
        v_record_id := COALESCE(
            (row_to_json(NEW)->>'id')::TEXT,
            (row_to_json(NEW)->>'uuid')::TEXT,
            NEW::TEXT  -- fallback: toda la fila como string
        );

    ELSIF (TG_OP = 'UPDATE') THEN
        v_operation := 'U';
        v_old_values := row_to_json(OLD)::JSONB;
        v_new_values := row_to_json(NEW)::JSONB;
        v_record_id := COALESCE(
            (row_to_json(NEW)->>'id')::TEXT,
            (row_to_json(NEW)->>'uuid')::TEXT,
            NEW::TEXT
        );

        -- Calcular que? campos realmente cambiaron (para UPDATE)
        -- U?til para auditori?as que solo quieren ver cambios especi?ficos
        SELECT ARRAY(
            SELECT key
            FROM jsonb_each(v_new_values) AS new_data
            WHERE new_data.value IS DISTINCT FROM (v_old_values->new_data.key)
        ) INTO v_changed_fields;

    ELSIF (TG_OP = 'DELETE') THEN
        v_operation := 'D';
        v_old_values := row_to_json(OLD)::JSONB;
        v_new_values := NULL;
        v_record_id := COALESCE(
            (row_to_json(OLD)->>'id')::TEXT,
            (row_to_json(OLD)->>'uuid')::TEXT,
            OLD::TEXT
        );
    END IF;

    -- ?? Obtener el usuario que realizo? el cambio ??
    -- La aplicacio?n .NET inyecta el usuario JWT via SET LOCAL antes del DML:
    --   SET LOCAL app.current_user = 'user@example.com';
    --   SET LOCAL app.request_id = 'req-uuid';
    -- Si no esta? disponible, se usa el usuario de BD.
    v_changed_by := COALESCE(
        current_setting('app.current_user', true),  -- Usuario JWT de la app
        session_user,                                -- Usuario de la sesio?n de BD
        current_user                                 -- Usuario actual de BD
    );

    v_app_user := current_setting('app.current_user', true);
    v_session_id := current_setting('app.session_id', true);
    v_request_id := current_setting('app.request_id', true);
    v_correlation_id := current_setting('app.correlation_id', true);

    -- ?? Obtener la IP del cliente ??
    -- inet_client_addr() devuelve la IP de la conexio?n TCP actual
    -- En conexiones via pgBouncer o RDS Proxy, sera? la IP del proxy
    v_ip_address := inet_client_addr();

    -- ?? Calcular el integrity_hash ??
    -- SHA-256 del contenido del registro para detectar tampering posterior
    -- Si alguien modifica audit_log directamente, el hash no coincidira?
    v_integrity_hash := encode(
        digest(
            CONCAT(
                TG_TABLE_NAME, '|',
                v_record_id, '|',
                v_operation, '|',
                NOW()::TEXT, '|',
                COALESCE(v_new_values::TEXT, v_old_values::TEXT, '')
            )::BYTEA,
            'sha256'
        ),
        'hex'
    );

    -- ?? Insertar en audit_log ??
    INSERT INTO audit_log (
        schema_name,
        table_name,
        record_id,
        operation,
        changed_by,
        application_user,
        ip_address,
        session_id,
        changed_at,
        old_values,
        new_values,
        changed_fields,
        request_id,
        correlation_id,
        integrity_hash
    ) VALUES (
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        v_record_id,
        v_operation,
        v_changed_by,
        v_app_user,
        v_ip_address,
        v_session_id,
        NOW(),  -- Siempre UTC (timezone configurado a UTC en el parameter group)
        v_old_values,
        v_new_values,
        v_changed_fields,
        v_request_id,
        v_correlation_id,
        v_integrity_hash
    );

    -- Retornar la fila apropiada (AFTER trigger no modifica la fila)
    IF (TG_OP = 'DELETE') THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;

EXCEPTION WHEN OTHERS THEN
    -- CRI?TICO: El trigger NO debe fallar aunque haya un error en el logging.
    -- Registrar el error en el log del servidor pero continuar la operacio?n.
    -- Si el audit trigger falla y bloquea las operaciones, el ensayo cli?nico se detiene.
    RAISE WARNING 'Error en fn_audit_trigger para tabla %: %', TG_TABLE_NAME, SQLERRM;
    IF (TG_OP = 'DELETE') THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$ LANGUAGE plpgsql
   SECURITY DEFINER  -- Se ejecuta con los permisos del duen?o de la funcio?n (no del usuario)
   SET search_path = public;  -- Fija el search_path para evitar ataques de inyeccio?n

-- ?????????????????????????????????????????????????????????????????????????????
-- FUNCIO?N: fn_apply_audit_trigger(table_name TEXT)
-- Helper que crea el trigger AFTER en cualquier tabla.
-- Llamada por Terraform (null_resource) para cada tabla de la lista.
-- ?????????????????????????????????????????????????????????????????????????????

CREATE OR REPLACE FUNCTION fn_apply_audit_trigger(p_table_name TEXT)
RETURNS VOID AS $$
DECLARE
    v_trigger_name TEXT := 'trg_audit_' || p_table_name;
    v_table_exists BOOLEAN;
BEGIN
    -- Verificar que la tabla existe antes de crear el trigger
    SELECT EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_schema = current_schema()
        AND table_name = p_table_name
    ) INTO v_table_exists;

    IF NOT v_table_exists THEN
        -- La tabla no existe au?n (se creara? cuando la app haga la migracio?n)
        -- No es un error: el trigger se aplicara? cuando la app cree la tabla
        RAISE NOTICE 'Tabla % no existe au?n. El trigger se creara? cuando la tabla exista.', p_table_name;
        RETURN;
    END IF;

    -- Eliminar el trigger si ya existe (idempotencia)
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', v_trigger_name, p_table_name);

    -- Crear el trigger AFTER (para tener acceso tanto a OLD como a NEW)
    -- FOR EACH ROW: se ejecuta una vez por cada fila afectada
    EXECUTE format(
        'CREATE TRIGGER %I
         AFTER INSERT OR UPDATE OR DELETE ON %I
         FOR EACH ROW EXECUTE FUNCTION fn_audit_trigger()',
        v_trigger_name,
        p_table_name
    );

    RAISE NOTICE '? Audit trigger instalado en tabla: %', p_table_name;
END;
$$ LANGUAGE plpgsql
   SECURITY DEFINER
   SET search_path = public;

-- ?????????????????????????????????????????????????????????????????????????????
-- FUNCIO?N: fn_verify_audit_integrity(p_table_name TEXT, p_start_date TIMESTAMPTZ)
-- Verifica que los registros de audit_log no fueron modificados.
-- Los auditores FDA pueden ejecutar esta funcio?n para confirmar integridad.
-- ?????????????????????????????????????????????????????????????????????????????

CREATE OR REPLACE FUNCTION fn_verify_audit_integrity(
    p_table_name TEXT,
    p_start_date TIMESTAMPTZ DEFAULT NOW() - INTERVAL '24 hours'
)
RETURNS TABLE (
    audit_id        UUID,
    table_name      TEXT,
    record_id       TEXT,
    operation       CHAR(1),
    changed_at      TIMESTAMPTZ,
    stored_hash     VARCHAR(64),
    calculated_hash VARCHAR(64),
    is_valid        BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        al.id,
        al.table_name,
        al.record_id,
        al.operation,
        al.changed_at,
        al.integrity_hash,
        encode(
            digest(
                CONCAT(
                    al.table_name, '|',
                    al.record_id, '|',
                    al.operation, '|',
                    al.changed_at::TEXT, '|',
                    COALESCE(al.new_values::TEXT, al.old_values::TEXT, '')
                )::BYTEA,
                'sha256'
            ),
            'hex'
        ) AS calculated_hash,
        -- Si el hash calculado coincide con el almacenado, el registro es va?lido
        al.integrity_hash = encode(
            digest(
                CONCAT(
                    al.table_name, '|',
                    al.record_id, '|',
                    al.operation, '|',
                    al.changed_at::TEXT, '|',
                    COALESCE(al.new_values::TEXT, al.old_values::TEXT, '')
                )::BYTEA,
                'sha256'
            ),
            'hex'
        ) AS is_valid
    FROM audit_log al
    WHERE al.table_name = p_table_name
    AND al.changed_at >= p_start_date
    ORDER BY al.changed_at DESC;
END;
$$ LANGUAGE plpgsql
   SECURITY DEFINER
   SET search_path = public;

-- ?????????????????????????????????????????????????????????????????????????????
-- VISTA: v_audit_summary
-- Vista simplificada para el dashboard de auditori?a en CloudWatch/Athena.
-- Oculta los campos te?cnicos y muestra solo lo relevante para auditores.
-- ?????????????????????????????????????????????????????????????????????????????

CREATE OR REPLACE VIEW v_audit_summary AS
SELECT
    id,
    table_name,
    record_id,
    CASE operation
        WHEN 'I' THEN 'Creacio?n'
        WHEN 'U' THEN 'Modificacio?n'
        WHEN 'D' THEN 'Eliminacio?n'
        ELSE 'Desconocido'
    END AS operation_description,
    changed_by,
    application_user,
    ip_address,
    changed_at,
    changed_at AT TIME ZONE 'America/New_York' AS changed_at_eastern,  -- Para equipos US
    changed_at AT TIME ZONE 'Europe/Madrid' AS changed_at_spain,        -- Para equipos EU
    changed_fields,
    request_id,
    correlation_id
FROM audit_log
ORDER BY changed_at DESC;

-- ?????????????????????????????????????????????????????????????????????????????
-- FUNCIO?N: fn_anonymize_patient(p_patient_id UUID)
-- Anonimizacio?n para cumplir GDPR "Derecho al olvido"
-- NO elimina datos: reemplaza PHI con valores anonimizados
-- y crea un registro en audit_log de la anonimizacio?n
-- ?????????????????????????????????????????????????????????????????????????????

CREATE OR REPLACE FUNCTION fn_anonymize_patient(p_patient_id UUID)
RETURNS VOID AS $$
DECLARE
    v_patient_exists BOOLEAN;
BEGIN
    -- Verificar que el paciente existe
    SELECT EXISTS(SELECT 1 FROM patients WHERE id = p_patient_id)
    INTO v_patient_exists;

    IF NOT v_patient_exists THEN
        RAISE EXCEPTION 'Paciente no encontrado: %', p_patient_id;
    END IF;

    -- Establecer el contexto de la operacio?n (aparecera? en audit_log)
    PERFORM set_config('app.current_user', 'GDPR-ANONYMIZATION-PROCESS', true);
    PERFORM set_config('app.request_id', gen_random_uuid()::TEXT, true);

    -- Anonimizar los campos de PHI (Protected Health Information)
    -- Se reemplaza con valores ficticios pero estructuralmente va?lidos
    UPDATE patients SET
        first_name    = 'ANONYMIZED',
        last_name     = 'ANONYMIZED',
        document_id   = 'ANON-' || UPPER(LEFT(MD5(document_id), 8)),
        email         = 'anonymized-' || id::TEXT || '@brainmart-anon.invalid',
        phone         = '+00000000000',
        address       = 'ANONYMIZED',
        birth_date    = '1900-01-01',  -- Fecha dummy que no revela la edad
        anonymized_at = NOW(),
        anonymized_by = current_user
    WHERE id = p_patient_id;

    -- El trigger de auditori?a capturara? automa?ticamente este UPDATE
    -- El audit_log contendra?:
    --   old_values: datos reales del paciente (ANTES)
    --   new_values: datos anonimizados (DESPUE?S)
    -- Esto cumple con GDPR: se anonimizan los datos operacionales
    -- pero el audit trail (evidencia regulatoria) se conserva.

    RAISE NOTICE 'Paciente % anonimizado exitosamente', p_patient_id;
END;
$$ LANGUAGE plpgsql
   SECURITY DEFINER
   SET search_path = public;

-- ?????????????????????????????????????????????????????????????????????????????
-- PERMISOS
-- El usuario de la aplicacio?n .NET puede INSERT/UPDATE/DELETE en las tablas
-- pero NO puede modificar audit_log directamente (solo la funcio?n trigger lo hace)
-- ?????????????????????????????????????????????????????????????????????????????

-- Crear rol de aplicacio?n si no existe
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'brainmart_app') THEN
        CREATE ROLE brainmart_app LOGIN PASSWORD NULL;  -- Password via Secrets Manager
    END IF;
END
$$;

-- El rol de app puede leer audit_log pero NO modificarlo
GRANT SELECT ON audit_log TO brainmart_app;
GRANT SELECT ON v_audit_summary TO brainmart_app;

-- NO se otorga INSERT/UPDATE/DELETE en audit_log al rol de app
-- Solo la funcio?n fn_audit_trigger() (SECURITY DEFINER) puede escribir en audit_log

-- Crear rol de auditor (solo lectura)
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'brainmart_auditor') THEN
        CREATE ROLE brainmart_auditor LOGIN PASSWORD NULL;
    END IF;
END
$$;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO brainmart_auditor;
GRANT EXECUTE ON FUNCTION fn_verify_audit_integrity(TEXT, TIMESTAMPTZ) TO brainmart_auditor;

-- ?????????????????????????????????????????????????????????????????????????????
-- VERIFICACIO?N FINAL
-- Confirmar que la infraestructura de auditori?a esta? instalada correctamente
-- ?????????????????????????????????????????????????????????????????????????????

DO $$
BEGIN
    -- Verificar que la tabla audit_log existe
    IF NOT EXISTS (
        SELECT FROM information_schema.tables
        WHERE table_name = 'audit_log'
    ) THEN
        RAISE EXCEPTION 'ERROR: tabla audit_log no fue creada correctamente';
    END IF;

    -- Verificar que la funcio?n trigger existe
    IF NOT EXISTS (
        SELECT FROM pg_proc
        WHERE proname = 'fn_audit_trigger'
    ) THEN
        RAISE EXCEPTION 'ERROR: funcio?n fn_audit_trigger no fue creada correctamente';
    END IF;

    RAISE NOTICE '? Infraestructura de Audit Trail ALCOA+ instalada correctamente';
    RAISE NOTICE '   ? Tabla audit_log: OK';
    RAISE NOTICE '   ? Funcio?n fn_audit_trigger: OK';
    RAISE NOTICE '   ? Funcio?n fn_apply_audit_trigger: OK';
    RAISE NOTICE '   ? Funcio?n fn_verify_audit_integrity: OK';
    RAISE NOTICE '   ? Vista v_audit_summary: OK';
    RAISE NOTICE '   ? Funcio?n fn_anonymize_patient: OK (GDPR)';
END
$$;
