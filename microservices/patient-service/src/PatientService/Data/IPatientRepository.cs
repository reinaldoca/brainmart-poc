// Data/IPatientRepository.cs
// Repository interface for Patient aggregate.
// Concrete implementation uses raw Npgsql to maintain compatibility
// with PostgreSQL row-level audit triggers (SET LOCAL app.current_user).

using PatientService.Models;

namespace PatientService.Data;

public interface IPatientRepository
{
    Task<PaginatedResult<PatientSummaryDto>> GetAllAsync(
        int page, int pageSize, string? trialId, CancellationToken ct = default);

    Task<Patient?> GetByIdAsync(Guid id, CancellationToken ct = default);

    Task<Patient> CreateAsync(Patient patient, CancellationToken ct = default);

    Task<Patient> UpdateAsync(Patient patient, CancellationToken ct = default);

    /// <summary>
    /// Replaces all PHI fields with anonymized values (GDPR Art. 17).
    /// The audit trail of previous changes is preserved as regulatory evidence.
    /// Delegates to PostgreSQL function fn_anonymize_patient().
    /// </summary>
    Task AnonymizeAsync(Guid id, string requestedBy, CancellationToken ct = default);

    Task<IEnumerable<AuditLogEntry>> GetAuditTrailAsync(
        Guid patientId,
        DateTimeOffset? from = null,
        DateTimeOffset? to   = null,
        CancellationToken ct = default);
}
