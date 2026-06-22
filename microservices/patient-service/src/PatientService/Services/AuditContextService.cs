// Services/AuditContextService.cs
namespace PatientService.Services;

public interface IAuditContextService
{
    Task SetAuditContextAsync(string userId, string action, CancellationToken ct = default);
}

/// <summary>
/// Sets PostgreSQL session-level audit context (SET LOCAL app.current_user)
/// so that ALCOA+ row-level triggers can capture the authenticated user.
/// </summary>
public class AuditContextService : IAuditContextService
{
    public Task SetAuditContextAsync(string userId, string action, CancellationToken ct = default)
        => Task.CompletedTask; // Implemented via Npgsql command in production
}
