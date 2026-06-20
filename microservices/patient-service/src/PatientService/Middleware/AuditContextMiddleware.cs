// ─────────────────────────────────────────────────────────────────────────────
// Middleware/AuditContextMiddleware.cs
//
// PROPÓSITO: Inyectar el usuario JWT en el contexto de la sesión PostgreSQL
// ANTES de que cualquier query de la request se ejecute.
//
// Esto hace que los triggers de auditoría ALCOA+ capten el usuario real
// de la aplicación (no el usuario genérico del connection pool).
//
// SIN este middleware: audit_log.changed_by = "brainmart_admin" (usuario de BD)
// CON este middleware: audit_log.changed_by = "investigador@hospital.com" (usuario real)
//
// IMPLEMENTACIÓN:
//   Antes de cada request: SET LOCAL app.current_user = 'user@email.com'
//   El trigger fn_audit_trigger() lee: current_setting('app.current_user', true)
// ─────────────────────────────────────────────────────────────────────────────

using Npgsql;
using System.Security.Claims;

namespace PatientService.Middleware;

public class AuditContextMiddleware
{
    private readonly RequestDelegate _next;
    private readonly ILogger<AuditContextMiddleware> _logger;

    public AuditContextMiddleware(RequestDelegate next, ILogger<AuditContextMiddleware> logger)
    {
        _next   = next;
        _logger = logger;
    }

    public async Task InvokeAsync(HttpContext context, NpgsqlDataSource dataSource)
    {
        // Extraer información de auditoría de la request
        var userId        = context.User.FindFirst(ClaimTypes.NameIdentifier)?.Value
                         ?? context.User.FindFirst("sub")?.Value
                         ?? "anonymous";
        var sessionId     = context.User.FindFirst("sid")?.Value ?? string.Empty;
        var requestId     = context.TraceIdentifier;
        var clientIp      = context.Connection.RemoteIpAddress?.ToString() ?? string.Empty;
        var correlationId = context.Request.Headers["X-Correlation-Id"].FirstOrDefault()
                         ?? context.TraceIdentifier;

        // Establecer el contexto de auditoría en la sesión de PostgreSQL
        // SET LOCAL: solo aplica a la transacción actual
        // Los triggers de auditoría leerán estos valores via current_setting()
        try
        {
            await using var conn    = await dataSource.OpenConnectionAsync();
            await using var command = conn.CreateCommand();

            command.CommandText = @"
                SET LOCAL app.current_user    = @userId;
                SET LOCAL app.session_id      = @sessionId;
                SET LOCAL app.request_id      = @requestId;
                SET LOCAL app.client_ip       = @clientIp;
                SET LOCAL app.correlation_id  = @correlationId;
            ";

            command.Parameters.AddWithValue("userId",        userId);
            command.Parameters.AddWithValue("sessionId",     sessionId);
            command.Parameters.AddWithValue("requestId",     requestId);
            command.Parameters.AddWithValue("clientIp",      clientIp);
            command.Parameters.AddWithValue("correlationId", correlationId);

            await command.ExecuteNonQueryAsync();
        }
        catch (Exception ex)
        {
            // NO fallar la request si el audit context no se puede establecer
            // Logear el error para investigación, pero continuar
            _logger.LogWarning(ex,
                "No se pudo establecer audit context para userId={UserId}, requestId={RequestId}",
                userId, requestId);
        }

        // Agregar el correlation ID al response header para trazabilidad
        context.Response.Headers["X-Correlation-Id"] = correlationId;
        context.Response.Headers["X-Request-Id"]     = requestId;

        await _next(context);
    }
}
