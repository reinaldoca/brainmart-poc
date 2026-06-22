// ─────────────────────────────────────────────────────────────────────────────
// Controllers/PatientsController.cs
//
// CRUD de pacientes con:
//   - Cifrado KMS de campos PHI antes de persistir
//   - Audit context inyectado en cada operación (ALCOA+)
//   - Paginación para evitar leaks masivos de datos
//   - Validación de inputs para prevenir SQLi y XSS
// ─────────────────────────────────────────────────────────────────────────────

using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using PatientService.Data;
using PatientService.Models;
using PatientService.Services;
using System.Security.Claims;

namespace PatientService.Controllers;

[ApiController]
[Route("api/v1/[controller]")]
[Authorize]  // Todos los endpoints requieren autenticación
public class PatientsController : ControllerBase
{
    private readonly IPatientRepository   _repository;
    private readonly IEncryptionService   _encryption;
    private readonly IAuditContextService _auditContext;
    private readonly ILogger<PatientsController> _logger;

    public PatientsController(
        IPatientRepository repository,
        IEncryptionService encryption,
        IAuditContextService auditContext,
        ILogger<PatientsController> logger)
    {
        _repository   = repository;
        _encryption   = encryption;
        _auditContext = auditContext;
        _logger       = logger;
    }

    // ── GET /api/v1/patients ──────────────────────────────────────────────────
    /// <summary>Lista pacientes con paginación. Solo devuelve campos no PHI por defecto.</summary>
    [HttpGet]
    [ProducesResponseType(typeof(PaginatedResult<PatientSummaryDto>), 200)]
    public async Task<IActionResult> GetAll(
        [FromQuery] int page = 1,
        [FromQuery] int pageSize = 20,
        [FromQuery] string? trialId = null)
    {
        // Límite máximo por página: previene dumps masivos de datos de pacientes
        pageSize = Math.Min(pageSize, 100);

        _logger.LogInformation("Listando pacientes. Page: {Page}, Size: {Size}, Trial: {Trial}",
            page, pageSize, trialId);

        var result = await _repository.GetAllAsync(page, pageSize, trialId);

        // No devolver campos cifrados en el listado (solo en GET por ID)
        return Ok(result);
    }

    // ── GET /api/v1/patients/{id} ─────────────────────────────────────────────
    /// <summary>Obtiene un paciente por ID. Descifra campos PHI para el usuario autorizado.</summary>
    [HttpGet("{id:guid}")]
    [ProducesResponseType(typeof(PatientDto), 200)]
    [ProducesResponseType(404)]
    public async Task<IActionResult> GetById(Guid id)
    {
        var patient = await _repository.GetByIdAsync(id);
        if (patient is null)
            return NotFound(new { error = "Paciente no encontrado", id });

        // Descifrar los campos PHI para devolverlos al cliente autorizado
        // Solo se descifra en memoria; en BD siempre están cifrados
        var decrypted = await DecryptPatientFieldsAsync(patient);

        _logger.LogInformation("Paciente {PatientId} consultado por {UserId}",
            id, GetCurrentUserId());

        return Ok(decrypted);
    }

    // ── POST /api/v1/patients ─────────────────────────────────────────────────
    /// <summary>Crea un nuevo paciente. Cifra campos PHI con KMS antes de persistir.</summary>
    [HttpPost]
    [ProducesResponseType(typeof(PatientDto), 201)]
    [ProducesResponseType(400)]
    public async Task<IActionResult> Create([FromBody] CreatePatientRequest request)
    {
        if (!ModelState.IsValid)
            return BadRequest(ModelState);

        // ── Cifrar campos PHI con KMS Envelope Encryption ──
        // Los datos se cifran con una DEK (Data Encryption Key) que está
        // protegida por la CMK de KMS. En BD se guarda el campo cifrado
        // + el encrypted DEK. Para descifrar: KMS descifra el DEK, luego
        // el DEK descifra el campo.
        var encryptedPatient = new Patient
        {
            Id             = Guid.NewGuid(),
            // Campos PHI cifrados:
            FirstNameEncrypted  = await _encryption.EncryptAsync(request.FirstName),
            LastNameEncrypted   = await _encryption.EncryptAsync(request.LastName),
            DocumentIdEncrypted = await _encryption.EncryptAsync(request.DocumentId),
            EmailEncrypted      = await _encryption.EncryptAsync(request.Email),
            AddressEncrypted    = request.Address is not null
                ? await _encryption.EncryptAsync(request.Address)
                : null,
            // Campos no PHI (no cifrados, para permitir queries eficientes):
            TrialId        = request.TrialId,
            ConsentDate    = request.ConsentDate,
            Status         = PatientStatus.Active,
            CreatedAt      = DateTimeOffset.UtcNow,
            CreatedBy      = GetCurrentUserId()
        };

        // El audit context ya está inyectado en el middleware:
        // PostgreSQL SET LOCAL app.current_user = 'user@example.com'
        // El trigger fn_audit_trigger() capturará este valor automáticamente
        var created = await _repository.CreateAsync(encryptedPatient);

        _logger.LogInformation("Paciente creado. Id: {PatientId}, Trial: {TrialId}, By: {UserId}",
            created.Id, created.TrialId, GetCurrentUserId());

        // Descifrar para la respuesta (el cliente ve datos legibles)
        var response = await DecryptPatientFieldsAsync(created);

        return CreatedAtAction(nameof(GetById), new { id = created.Id }, response);
    }

    // ── PUT /api/v1/patients/{id} ─────────────────────────────────────────────
    [HttpPut("{id:guid}")]
    [ProducesResponseType(typeof(PatientDto), 200)]
    [ProducesResponseType(404)]
    public async Task<IActionResult> Update(Guid id, [FromBody] UpdatePatientRequest request)
    {
        if (!ModelState.IsValid)
            return BadRequest(ModelState);

        var existing = await _repository.GetByIdAsync(id);
        if (existing is null)
            return NotFound(new { error = "Paciente no encontrado", id });

        // Solo actualizar los campos que se enviaron (patch-like behavior)
        if (request.FirstName is not null)
            existing.FirstNameEncrypted = await _encryption.EncryptAsync(request.FirstName);
        if (request.LastName is not null)
            existing.LastNameEncrypted = await _encryption.EncryptAsync(request.LastName);
        if (request.Address is not null)
            existing.AddressEncrypted = await _encryption.EncryptAsync(request.Address);
        if (request.Status.HasValue)
            existing.Status = request.Status.Value;

        existing.UpdatedAt = DateTimeOffset.UtcNow;
        existing.UpdatedBy = GetCurrentUserId();

        var updated = await _repository.UpdateAsync(existing);
        return Ok(await DecryptPatientFieldsAsync(updated));
    }

    // ── DELETE /api/v1/patients/{id}/anonymize ────────────────────────────────
    /// <summary>
    /// Anonimiza un paciente (GDPR "derecho al olvido").
    /// NO elimina el registro: reemplaza PHI con valores anonimizados.
    /// El audit trail de cambios previos se conserva (evidencia regulatoria).
    /// </summary>
    [HttpPost("{id:guid}/anonymize")]
    [Authorize(Roles = "DataProtectionOfficer,Admin")]  // Solo DPO puede anonimizar
    [ProducesResponseType(204)]
    [ProducesResponseType(404)]
    public async Task<IActionResult> Anonymize(Guid id)
    {
        var existing = await _repository.GetByIdAsync(id);
        if (existing is null)
            return NotFound();

        // Llamar a la función SQL de anonimización (fn_anonymize_patient)
        // que también genera un registro en audit_log
        await _repository.AnonymizeAsync(id, GetCurrentUserId());

        _logger.LogWarning("Paciente {PatientId} anonimizado (GDPR) por {UserId}",
            id, GetCurrentUserId());

        return NoContent();
    }

    // ── GET /api/v1/patients/{id}/audit-trail ─────────────────────────────────
    /// <summary>Consulta el audit trail ALCOA+ de un paciente.</summary>
    [HttpGet("{id:guid}/audit-trail")]
    [Authorize(Roles = "Auditor,Admin,ClinicalResearcher")]
    [ProducesResponseType(typeof(IEnumerable<AuditLogEntry>), 200)]
    public async Task<IActionResult> GetAuditTrail(
        Guid id,
        [FromQuery] DateTimeOffset? from = null,
        [FromQuery] DateTimeOffset? to   = null)
    {
        var entries = await _repository.GetAuditTrailAsync(id, from, to);

        _logger.LogInformation("Audit trail de paciente {PatientId} consultado por {UserId}",
            id, GetCurrentUserId());

        return Ok(entries);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private string GetCurrentUserId() =>
        User.FindFirst(ClaimTypes.NameIdentifier)?.Value
        ?? User.FindFirst("sub")?.Value
        ?? "anonymous";

    private async Task<PatientDto> DecryptPatientFieldsAsync(Patient patient)
    {
        return new PatientDto
        {
            Id          = patient.Id,
            FirstName   = await _encryption.DecryptAsync(patient.FirstNameEncrypted),
            LastName    = await _encryption.DecryptAsync(patient.LastNameEncrypted),
            DocumentId  = await _encryption.DecryptAsync(patient.DocumentIdEncrypted),
            Email       = await _encryption.DecryptAsync(patient.EmailEncrypted),
            Address     = patient.AddressEncrypted is not null
                ? await _encryption.DecryptAsync(patient.AddressEncrypted)
                : null,
            TrialId     = patient.TrialId,
            ConsentDate = patient.ConsentDate,
            Status      = patient.Status,
            CreatedAt   = patient.CreatedAt,
            CreatedBy   = patient.CreatedBy
        };
    }
}
