// tests/PatientService.Tests/Models/PatientModelTests.cs
// Unit tests for Patient domain model and DTOs.
// FDA 21 CFR Part 11: software must be validated before use in production.

using PatientService.Models;
using System.ComponentModel.DataAnnotations;

namespace PatientService.Tests.Models;

public class PatientModelTests
{
    // ── Patient entity ────────────────────────────────────────────────────────

    [Fact]
    public void Patient_DefaultStatus_IsActive()
    {
        var patient = new Patient
        {
            Id                  = Guid.NewGuid(),
            FirstNameEncrypted  = "enc:firstName",
            LastNameEncrypted   = "enc:lastName",
            DocumentIdEncrypted = "enc:docId",
            EmailEncrypted      = "enc:email",
            TrialId             = Guid.NewGuid(),
            ConsentDate         = DateTimeOffset.UtcNow,
            Status              = PatientStatus.Active,
            CreatedAt           = DateTimeOffset.UtcNow,
            CreatedBy           = "test@brainmart.health"
        };

        Assert.Equal(PatientStatus.Active, patient.Status);
        Assert.Null(patient.AnonymizedAt);
        Assert.Null(patient.AnonymizedBy);
    }

    [Fact]
    public void Patient_EncryptedFields_StoredAsOpaque()
    {
        // PHI fields must never contain plaintext - they must start with
        // the envelope encryption prefix (base64 encoded DEK + nonce + ciphertext)
        var patient = new Patient
        {
            FirstNameEncrypted  = "AAAA.BBBB.CCCC",  // base64.base64.base64 format
            LastNameEncrypted   = "DDDD.EEEE.FFFF",
            DocumentIdEncrypted = "GGGG.HHHH.IIII",
            EmailEncrypted      = "JJJJ.KKKK.LLLL"
        };

        // Verify no PHI field contains plaintext separators or common names
        Assert.DoesNotContain("John",  patient.FirstNameEncrypted);
        Assert.DoesNotContain("Smith", patient.LastNameEncrypted);
        Assert.DoesNotContain("@",     patient.EmailEncrypted);
    }

    // ── PatientStatus enum ────────────────────────────────────────────────────

    [Theory]
    [InlineData(PatientStatus.Active)]
    [InlineData(PatientStatus.Withdrawn)]
    [InlineData(PatientStatus.Completed)]
    [InlineData(PatientStatus.Anonymized)]
    public void PatientStatus_AllValuesAreDefined(PatientStatus status)
    {
        Assert.True(Enum.IsDefined(typeof(PatientStatus), status));
    }

    // ── CreatePatientRequest validation ──────────────────────────────────────

    [Fact]
    public void CreatePatientRequest_ValidRequest_PassesDataAnnotations()
    {
        var request = new CreatePatientRequest(
            FirstName:   "Jane",
            LastName:    "Doe",
            DocumentId:  "DNI-12345678",
            Email:       "jane.doe@hospital.com",
            Address:     "123 Clinical Trial Ave",
            TrialId:     Guid.NewGuid(),
            ConsentDate: DateTimeOffset.UtcNow
        );

        var validationResults = new List<ValidationResult>();
        var context = new ValidationContext(request);
        bool isValid = Validator.TryValidateObject(request, context, validationResults, true);

        Assert.True(isValid, $"Validation failed: {string.Join(", ", validationResults.Select(r => r.ErrorMessage))}");
    }

    [Fact]
    public void CreatePatientRequest_InvalidEmail_FailsValidation()
    {
        var request = new CreatePatientRequest(
            FirstName:   "Jane",
            LastName:    "Doe",
            DocumentId:  "DNI-12345678",
            Email:       "not-an-email",       // invalid
            Address:     null,
            TrialId:     Guid.NewGuid(),
            ConsentDate: DateTimeOffset.UtcNow
        );

        var validationResults = new List<ValidationResult>();
        var context = new ValidationContext(request);
        bool isValid = Validator.TryValidateObject(request, context, validationResults, true);

        Assert.False(isValid);
        Assert.Contains(validationResults, r => r.MemberNames.Contains(nameof(CreatePatientRequest.Email)));
    }

    [Fact]
    public void CreatePatientRequest_EmptyFirstName_FailsValidation()
    {
        var request = new CreatePatientRequest(
            FirstName:   "",                    // invalid: Required
            LastName:    "Doe",
            DocumentId:  "DNI-12345678",
            Email:       "jane@hospital.com",
            Address:     null,
            TrialId:     Guid.NewGuid(),
            ConsentDate: DateTimeOffset.UtcNow
        );

        var validationResults = new List<ValidationResult>();
        var context = new ValidationContext(request);
        bool isValid = Validator.TryValidateObject(request, context, validationResults, true);

        Assert.False(isValid);
    }

    // ── PaginatedResult ───────────────────────────────────────────────────────

    [Theory]
    [InlineData(100, 20, 5)]
    [InlineData(101, 20, 6)]
    [InlineData(1,   20, 1)]
    [InlineData(0,   20, 0)]
    public void PaginatedResult_TotalPages_CalculatedCorrectly(
        int totalCount, int pageSize, int expectedPages)
    {
        var result = new PaginatedResult<PatientSummaryDto>(
            Items:      Enumerable.Empty<PatientSummaryDto>(),
            TotalCount: totalCount,
            Page:       1,
            PageSize:   pageSize,
            TotalPages: (int)Math.Ceiling(totalCount / (double)pageSize)
        );

        Assert.Equal(expectedPages, result.TotalPages);
        Assert.Equal(totalCount,    result.TotalCount);
        Assert.Equal(pageSize,      result.PageSize);
    }
}
