// Data/NpgsqlPatientRepository.cs
// PostgreSQL implementation using raw Npgsql (no EF Core).
//
// WHY RAW NPGSQL (not EF Core):
//   Each write operation executes SET LOCAL app.current_user = @userId
//   before the INSERT/UPDATE so that the PostgreSQL trigger fn_audit_trigger()
//   can capture the authenticated user for ALCOA+ audit trail compliance.
//   EF Core's interceptors cannot reliably inject SET LOCAL in the same
//   transaction without custom scaffolding.

using Npgsql;
using PatientService.Models;
using PatientService.Services;

namespace PatientService.Data;

public class NpgsqlPatientRepository : IPatientRepository
{
    private readonly NpgsqlDataSource _dataSource;
    private readonly IAuditContextService _auditContext;
    private readonly ILogger<NpgsqlPatientRepository> _logger;

    public NpgsqlPatientRepository(
        NpgsqlDataSource dataSource,
        IAuditContextService auditContext,
        ILogger<NpgsqlPatientRepository> logger)
    {
        _dataSource   = dataSource;
        _auditContext = auditContext;
        _logger       = logger;
    }

    public async Task<PaginatedResult<PatientSummaryDto>> GetAllAsync(
        int page, int pageSize, string? trialId, CancellationToken ct = default)
    {
        await using var conn = await _dataSource.OpenConnectionAsync(ct);
        await using var cmd  = conn.CreateCommand();

        cmd.CommandText = @"
            SELECT id, trial_id, status, created_at,
                   COUNT(*) OVER() AS total_count
            FROM patients
            WHERE ($1::uuid IS NULL OR trial_id = $1::uuid)
              AND status != 'Anonymized'
            ORDER BY created_at DESC
            OFFSET $2 ROWS FETCH NEXT $3 ROWS ONLY";

        cmd.Parameters.AddWithValue(trialId is null ? DBNull.Value : Guid.Parse(trialId));
        cmd.Parameters.AddWithValue((page - 1) * pageSize);
        cmd.Parameters.AddWithValue(pageSize);

        await using var reader = await cmd.ExecuteReaderAsync(ct);
        var items      = new List<PatientSummaryDto>();
        int totalCount = 0;

        while (await reader.ReadAsync(ct))
        {
            totalCount = reader.GetInt32(4);
            items.Add(new PatientSummaryDto(
                reader.GetGuid(0),
                reader.GetGuid(1),
                Enum.Parse<PatientStatus>(reader.GetString(2)),
                reader.GetFieldValue<DateTimeOffset>(3)));
        }

        return new PaginatedResult<PatientSummaryDto>(
            items, totalCount, page, pageSize,
            (int)Math.Ceiling(totalCount / (double)pageSize));
    }

    public async Task<Patient?> GetByIdAsync(Guid id, CancellationToken ct = default)
    {
        await using var conn = await _dataSource.OpenConnectionAsync(ct);
        await using var cmd  = conn.CreateCommand();

        cmd.CommandText = @"
            SELECT id, first_name_encrypted, last_name_encrypted,
                   document_id_encrypted, email_encrypted, address_encrypted,
                   trial_id, consent_date, status, created_at, created_by,
                   updated_at, updated_by, anonymized_at, anonymized_by
            FROM patients WHERE id = $1 LIMIT 1";
        cmd.Parameters.AddWithValue(id);

        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return null;

        return MapRow(reader);
    }

    public async Task<Patient> CreateAsync(Patient p, CancellationToken ct = default)
    {
        await using var conn = await _dataSource.OpenConnectionAsync(ct);
        await using var tx   = await conn.BeginTransactionAsync(ct);

        // ALCOA+: set session user so the audit trigger captures the creator
        await using (var setCmd = conn.CreateCommand())
        {
            setCmd.CommandText = "SELECT set_config('app.current_user', $1, true)";
            setCmd.Parameters.AddWithValue(p.CreatedBy);
            setCmd.Transaction = tx;
            await setCmd.ExecuteNonQueryAsync(ct);
        }

        await using var cmd = conn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = @"
            INSERT INTO patients (
                id, first_name_encrypted, last_name_encrypted,
                document_id_encrypted, email_encrypted, address_encrypted,
                trial_id, consent_date, status, created_at, created_by)
            VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
            RETURNING id";

        cmd.Parameters.AddWithValue(p.Id);
        cmd.Parameters.AddWithValue(p.FirstNameEncrypted);
        cmd.Parameters.AddWithValue(p.LastNameEncrypted);
        cmd.Parameters.AddWithValue(p.DocumentIdEncrypted);
        cmd.Parameters.AddWithValue(p.EmailEncrypted);
        cmd.Parameters.AddWithValue((object?)p.AddressEncrypted ?? DBNull.Value);
        cmd.Parameters.AddWithValue(p.TrialId);
        cmd.Parameters.AddWithValue(p.ConsentDate);
        cmd.Parameters.AddWithValue(p.Status.ToString());
        cmd.Parameters.AddWithValue(p.CreatedAt);
        cmd.Parameters.AddWithValue(p.CreatedBy);

        await cmd.ExecuteNonQueryAsync(ct);
        await tx.CommitAsync(ct);

        _logger.LogInformation("Patient {Id} created", p.Id);
        return p;
    }

    public async Task<Patient> UpdateAsync(Patient p, CancellationToken ct = default)
    {
        await using var conn = await _dataSource.OpenConnectionAsync(ct);
        await using var tx   = await conn.BeginTransactionAsync(ct);

        await using (var setCmd = conn.CreateCommand())
        {
            setCmd.CommandText = "SELECT set_config('app.current_user', $1, true)";
            setCmd.Parameters.AddWithValue(p.UpdatedBy ?? "system");
            setCmd.Transaction = tx;
            await setCmd.ExecuteNonQueryAsync(ct);
        }

        await using var cmd = conn.CreateCommand();
        cmd.Transaction = tx;
        cmd.CommandText = @"
            UPDATE patients SET
                first_name_encrypted  = $2,
                last_name_encrypted   = $3,
                address_encrypted     = $4,
                status                = $5,
                updated_at            = $6,
                updated_by            = $7
            WHERE id = $1";

        cmd.Parameters.AddWithValue(p.Id);
        cmd.Parameters.AddWithValue(p.FirstNameEncrypted);
        cmd.Parameters.AddWithValue(p.LastNameEncrypted);
        cmd.Parameters.AddWithValue((object?)p.AddressEncrypted ?? DBNull.Value);
        cmd.Parameters.AddWithValue(p.Status.ToString());
        cmd.Parameters.AddWithValue(p.UpdatedAt ?? DateTimeOffset.UtcNow);
        cmd.Parameters.AddWithValue(p.UpdatedBy ?? "system");

        await cmd.ExecuteNonQueryAsync(ct);
        await tx.CommitAsync(ct);

        return p;
    }

    public async Task AnonymizeAsync(Guid id, string requestedBy, CancellationToken ct = default)
    {
        await using var conn = await _dataSource.OpenConnectionAsync(ct);
        await using var cmd  = conn.CreateCommand();

        // Delegates to PostgreSQL stored procedure that also writes to audit_log
        cmd.CommandText = "CALL fn_anonymize_patient($1, $2)";
        cmd.Parameters.AddWithValue(id);
        cmd.Parameters.AddWithValue(requestedBy);

        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<IEnumerable<AuditLogEntry>> GetAuditTrailAsync(
        Guid patientId,
        DateTimeOffset? from = null,
        DateTimeOffset? to   = null,
        CancellationToken ct = default)
    {
        await using var conn = await _dataSource.OpenConnectionAsync(ct);
        await using var cmd  = conn.CreateCommand();

        cmd.CommandText = @"
            SELECT id, table_name, record_id, operation_description,
                   changed_by, application_user, ip_address,
                   changed_at, changed_fields, is_integrity_valid
            FROM audit_log
            WHERE record_id = $1::text
              AND ($2::timestamptz IS NULL OR changed_at >= $2)
              AND ($3::timestamptz IS NULL OR changed_at <= $3)
            ORDER BY changed_at DESC";

        cmd.Parameters.AddWithValue(patientId.ToString());
        cmd.Parameters.AddWithValue((object?)from ?? DBNull.Value);
        cmd.Parameters.AddWithValue((object?)to   ?? DBNull.Value);

        await using var reader = await cmd.ExecuteReaderAsync(ct);
        var entries = new List<AuditLogEntry>();

        while (await reader.ReadAsync(ct))
        {
            entries.Add(new AuditLogEntry(
                reader.GetGuid(0),
                reader.GetString(1),
                reader.GetString(2),
                reader.GetString(3),
                reader.GetString(4),
                reader.IsDBNull(5) ? null : reader.GetString(5),
                reader.IsDBNull(6) ? null : reader.GetString(6),
                reader.GetFieldValue<DateTimeOffset>(7),
                reader.IsDBNull(8) ? null : reader.GetFieldValue<string[]>(8),
                reader.GetBoolean(9)
            ));
        }

        return entries;
    }

    private static Patient MapRow(NpgsqlDataReader r) => new()
    {
        Id                    = r.GetGuid(0),
        FirstNameEncrypted    = r.GetString(1),
        LastNameEncrypted     = r.GetString(2),
        DocumentIdEncrypted   = r.GetString(3),
        EmailEncrypted        = r.GetString(4),
        AddressEncrypted      = r.IsDBNull(5) ? null : r.GetString(5),
        TrialId               = r.GetGuid(6),
        ConsentDate           = r.GetFieldValue<DateTimeOffset>(7),
        Status                = Enum.Parse<PatientStatus>(r.GetString(8)),
        CreatedAt             = r.GetFieldValue<DateTimeOffset>(9),
        CreatedBy             = r.GetString(10),
        UpdatedAt             = r.IsDBNull(11) ? null : r.GetFieldValue<DateTimeOffset>(11),
        UpdatedBy             = r.IsDBNull(12) ? null : r.GetString(12),
        AnonymizedAt          = r.IsDBNull(13) ? null : r.GetFieldValue<DateTimeOffset>(13),
        AnonymizedBy          = r.IsDBNull(14) ? null : r.GetString(14),
    };
}
