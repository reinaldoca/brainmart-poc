// ─────────────────────────────────────────────────────────────────────────────
// Models/Patient.cs — Entidades del dominio
// ─────────────────────────────────────────────────────────────────────────────

using System.ComponentModel.DataAnnotations;

namespace PatientService.Models;

/// <summary>
/// Entidad de paciente. Los campos PHI se almacenan cifrados con KMS.
/// Campos no PHI (TrialId, Status, etc.) sin cifrar para permitir queries eficientes.
/// </summary>
public class Patient
{
    public Guid   Id    { get; set; }

    // ── Campos PHI (cifrados con KMS Envelope Encryption) ──
    public string FirstNameEncrypted  { get; set; } = string.Empty;
    public string LastNameEncrypted   { get; set; } = string.Empty;
    public string DocumentIdEncrypted { get; set; } = string.Empty;
    public string EmailEncrypted      { get; set; } = string.Empty;
    public string? AddressEncrypted   { get; set; }

    // ── Campos no PHI (no cifrados) ──
    public Guid            TrialId     { get; set; }
    public DateTimeOffset  ConsentDate { get; set; }
    public PatientStatus   Status      { get; set; }
    public DateTimeOffset  CreatedAt   { get; set; }
    public string          CreatedBy   { get; set; } = string.Empty;
    public DateTimeOffset? UpdatedAt   { get; set; }
    public string?         UpdatedBy   { get; set; }
    public DateTimeOffset? AnonymizedAt { get; set; }
    public string?         AnonymizedBy { get; set; }
}

public enum PatientStatus { Active, Withdrawn, Completed, Anonymized }

// ── DTOs ──────────────────────────────────────────────────────────────────────

public record PatientDto(
    Guid   Id,
    string FirstName,
    string LastName,
    string DocumentId,
    string Email,
    string? Address,
    Guid   TrialId,
    DateTimeOffset ConsentDate,
    PatientStatus  Status,
    DateTimeOffset CreatedAt,
    string CreatedBy
);

public record PatientSummaryDto(Guid Id, Guid TrialId, PatientStatus Status, DateTimeOffset CreatedAt);

public record CreatePatientRequest(
    [property: Required][property: StringLength(100)] string FirstName,
    [property: Required][property: StringLength(100)] string LastName,
    [property: Required][property: StringLength(20)]  string DocumentId,
    [property: Required][property: EmailAddress]      string Email,
    [property: StringLength(500)]                     string? Address,
    [property: Required] Guid   TrialId,
    [property: Required] DateTimeOffset ConsentDate
);

public record UpdatePatientRequest(
    [StringLength(100)] string?       FirstName,
    [StringLength(100)] string?       LastName,
    [StringLength(500)] string?       Address,
    PatientStatus?                    Status
);

public record AuditLogEntry(
    Guid           Id,
    string         TableName,
    string         RecordId,
    string         OperationDescription,
    string         ChangedBy,
    string?        ApplicationUser,
    string?        IpAddress,
    DateTimeOffset ChangedAt,
    string[]?      ChangedFields,
    bool           IsIntegrityValid
);

public record PaginatedResult<T>(
    IEnumerable<T> Items,
    int            TotalCount,
    int            Page,
    int            PageSize,
    int            TotalPages
);
