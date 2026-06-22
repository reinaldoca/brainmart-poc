// Data/PatientDbContext.cs
// Stub required for build. Full implementation connects to PostgreSQL via Npgsql.
namespace PatientService.Data;

/// <summary>
/// Database context stub - actual queries use raw Npgsql for
/// ALCOA+ audit trigger compatibility (SET LOCAL app.current_user).
/// </summary>
public class PatientDbContext
{
    // Intentionally minimal - service uses Npgsql directly (not EF Core)
    // to maintain compatibility with PostgreSQL row-level audit triggers.
}
