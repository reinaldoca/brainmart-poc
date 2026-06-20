// ─────────────────────────────────────────────────────────────────────────────
// Program.cs — Patient Service .NET 8
//
// Entry point del microservicio. Configura:
//   - Autenticación JWT con HttpOnly cookies (no Bearer header)
//   - X-Ray para trazas distribuidas
//   - Serilog para logging estructurado
//   - Health checks para ALB + ECS
//   - KMS envelope encryption para campos PHI (nombre, DNI, dirección)
//   - Audit context: inyecta usuario JWT en PostgreSQL SET LOCAL
// ─────────────────────────────────────────────────────────────────────────────

using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;
using Amazon.XRay.Recorder.Handlers.AspNetCore;
using Serilog;
using Serilog.Formatting.Json;
using PatientService.Services;
using PatientService.Middleware;
using PatientService.Data;

var builder = WebApplication.CreateBuilder(args);

// ── Serilog: logging estructurado en JSON (legible por CloudWatch Insights) ──
Log.Logger = new LoggerConfiguration()
    .ReadFrom.Configuration(builder.Configuration)
    .Enrich.FromLogContext()
    .Enrich.WithMachineName()
    .Enrich.WithEnvironmentName()
    .WriteTo.Console(new JsonFormatter())  // CloudWatch recibe JSON
    .CreateLogger();

builder.Host.UseSerilog();

// ── Servicios ──
builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(c =>
{
    c.SwaggerDoc("v1", new() {
        Title = "Brainmart Patient Service API",
        Version = "v1",
        Description = "FDA 21 CFR Part 11 Compliant · ALCOA+ Audit Trail · GDPR"
    });
});

// ── PostgreSQL via Npgsql ──
builder.Services.AddNpgsqlDataSource(
    builder.Configuration.GetConnectionString("DefaultConnection")
    ?? throw new InvalidOperationException("Connection string 'DefaultConnection' not found."));

// ── KMS Encryption Service para campos PHI ──
builder.Services.AddSingleton<IEncryptionService, KmsEncryptionService>();

// ── Audit Service: inyecta contexto ALCOA+ en cada request ──
builder.Services.AddScoped<IAuditContextService, AuditContextService>();

// ── AWS X-Ray para trazas distribuidas ──
builder.Services.AddAWSService<Amazon.XRay.AmazonXRayConfig>();

// ── JWT Authentication con HttpOnly Cookies ──
// SEGURIDAD: JWT en HttpOnly Cookie (no localStorage) previene XSS
var jwtSigningKey = builder.Configuration["JWT:SigningKey"]
    ?? throw new InvalidOperationException("JWT signing key not configured.");

builder.Services.AddAuthentication(options =>
{
    options.DefaultAuthenticateScheme = JwtBearerDefaults.AuthenticationScheme;
    options.DefaultChallengeScheme    = JwtBearerDefaults.AuthenticationScheme;
})
.AddJwtBearer(options =>
{
    options.TokenValidationParameters = new TokenValidationParameters
    {
        ValidateIssuer           = true,
        ValidateAudience         = true,
        ValidateLifetime         = true,
        ValidateIssuerSigningKey = true,
        ValidIssuer              = builder.Configuration["JWT:Issuer"],
        ValidAudience            = builder.Configuration["JWT:Audience"],
        IssuerSigningKey         = new SymmetricSecurityKey(
            System.Text.Encoding.UTF8.GetBytes(jwtSigningKey)),
        ClockSkew = TimeSpan.Zero  // Sin tolerancia de tiempo (más estricto)
    };

    // Leer el JWT desde la HttpOnly Cookie (no el Authorization header)
    // Esto previene ataques XSS que roban tokens del localStorage/sessionStorage
    options.Events = new JwtBearerEvents
    {
        OnMessageReceived = context =>
        {
            // Intentar leer de cookie primero, luego del header Authorization
            var cookie = context.Request.Cookies["brainmart_access_token"];
            if (!string.IsNullOrEmpty(cookie))
            {
                context.Token = cookie;
            }
            return Task.CompletedTask;
        }
    };
});

builder.Services.AddAuthorization();

// ── CORS: solo el dominio de la SPA Angular puede hacer requests ──
builder.Services.AddCors(options =>
{
    options.AddPolicy("BrainmartSPA", policy =>
    {
        var allowedOrigins = builder.Configuration.GetSection("Cors:AllowedOrigins")
            .Get<string[]>() ?? Array.Empty<string>();
        policy
            .WithOrigins(allowedOrigins)
            .AllowAnyMethod()
            .AllowAnyHeader()
            .AllowCredentials();  // Necesario para que las cookies se envíen en CORS
    });
});

// ── Health Checks ──
builder.Services.AddHealthChecks()
    .AddNpgSql(
        connectionString: builder.Configuration.GetConnectionString("DefaultConnection")!,
        name: "database",
        tags: new[] { "db", "postgresql" })
    .AddCheck<AuditTrailHealthCheck>("audit-trail",
        tags: new[] { "audit", "alcoa" });

var app = builder.Build();

// ── Middleware pipeline (orden importa) ──

// X-Ray: debe ser el primer middleware para trazar toda la request
app.UseXRay("patient-service");

// Logging de requests HTTP
app.UseSerilogRequestLogging(options =>
{
    options.EnrichDiagnosticContext = (diagnosticContext, httpContext) =>
    {
        // Agregar campos de auditoría al log de cada request
        diagnosticContext.Set("RequestId",   httpContext.TraceIdentifier);
        diagnosticContext.Set("UserAgent",   httpContext.Request.Headers.UserAgent.ToString());
        diagnosticContext.Set("ClientIp",    httpContext.Connection.RemoteIpAddress?.ToString());
        diagnosticContext.Set("UserId",      httpContext.User.FindFirst("sub")?.Value ?? "anonymous");
        diagnosticContext.Set("Environment", builder.Environment.EnvironmentName);
    };
});

// HTTPS Redirection
app.UseHttpsRedirection();

// CORS
app.UseCors("BrainmartSPA");

// Autenticación y Autorización
app.UseAuthentication();
app.UseAuthorization();

// Middleware de Audit Context: inyecta el usuario JWT en el contexto de PostgreSQL
// Esto hace que los triggers de auditoría ALCOA+ capturen el usuario real
app.UseMiddleware<AuditContextMiddleware>();

// Swagger (solo en dev/staging)
if (app.Environment.IsDevelopment() || app.Environment.IsStaging())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.MapControllers();

// Health check endpoints (sin autenticación para que el ALB pueda verificar)
app.MapHealthChecks("/health");
app.MapHealthChecks("/health/audit", new Microsoft.AspNetCore.Diagnostics.HealthChecks.HealthCheckOptions
{
    Predicate = check => check.Tags.Contains("audit")
});

try
{
    Log.Information("🚀 Brainmart Patient Service iniciando en {Environment}",
        builder.Environment.EnvironmentName);
    app.Run();
}
catch (Exception ex)
{
    Log.Fatal(ex, "Patient Service falló al iniciar");
    throw;
}
finally
{
    Log.CloseAndFlush();
}
