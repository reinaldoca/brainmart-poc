// tests/PatientService.Tests/Services/EncryptionServiceTests.cs
// Unit tests for KMS Envelope Encryption service.
// Verifies that PHI fields are properly encrypted/decrypted without hitting real KMS.

using Amazon.KeyManagementService;
using Amazon.KeyManagementService.Model;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Moq;
using PatientService.Services;
using System.Security.Cryptography;
using Xunit;

namespace PatientService.Tests.Services;

public class EncryptionServiceTests
{
    private readonly Mock<IAmazonKeyManagementService> _kmsMock;
    private readonly Mock<IConfiguration>              _configMock;
    private readonly Mock<ILogger<KmsEncryptionService>> _loggerMock;
    private readonly KmsEncryptionService _sut;

    private const string FakeKmsKeyId = "arn:aws:kms:us-east-1:123456789012:key/fake-key-id";

    public EncryptionServiceTests()
    {
        _kmsMock    = new Mock<IAmazonKeyManagementService>();
        _configMock = new Mock<IConfiguration>();
        _loggerMock = new Mock<ILogger<KmsEncryptionService>>();

        _configMock.Setup(c => c["KMS:KeyId"]).Returns(FakeKmsKeyId);

        // Mock: GenerateDataKey returns a fake 32-byte DEK
        var fakeDek           = RandomNumberGenerator.GetBytes(32);
        var fakeEncryptedDek  = RandomNumberGenerator.GetBytes(64);

        _kmsMock.Setup(k => k.GenerateDataKeyAsync(
                It.IsAny<GenerateDataKeyRequest>(),
                It.IsAny<CancellationToken>()))
            .ReturnsAsync(new GenerateDataKeyResponse
            {
                Plaintext      = new MemoryStream(fakeDek),
                CiphertextBlob = new MemoryStream(fakeEncryptedDek)
            });

        // Mock: Decrypt returns the same fake DEK (round-trip)
        _kmsMock.Setup(k => k.DecryptAsync(
                It.IsAny<DecryptRequest>(),
                It.IsAny<CancellationToken>()))
            .ReturnsAsync(new DecryptResponse
            {
                Plaintext = new MemoryStream(fakeDek)
            });

        _sut = new KmsEncryptionService(_kmsMock.Object, _configMock.Object, _loggerMock.Object);
    }

    [Fact]
    public async Task EncryptAsync_Plaintext_ReturnsThreePartBase64String()
    {
        // Arrange
        const string plaintext = "John";

        // Act
        var encrypted = await _sut.EncryptAsync(plaintext);

        // Assert: format is encryptedDek.nonce.ciphertext (3 base64 parts)
        var parts = encrypted.Split('.');
        Assert.Equal(3, parts.Length);
        foreach (var part in parts)
        {
            Assert.NotEmpty(part);
            // Each part must be valid base64
            Assert.True(IsValidBase64(part), $"Part '{part}' is not valid base64");
        }
    }

    [Fact]
    public async Task EncryptAsync_SamePlaintext_ReturnsDifferentCiphertextEachTime()
    {
        // AES-GCM uses a random nonce per encryption - same plaintext never produces
        // the same ciphertext (semantic security / IND-CPA property)
        const string plaintext = "Jane";

        var encrypted1 = await _sut.EncryptAsync(plaintext);
        var encrypted2 = await _sut.EncryptAsync(plaintext);

        Assert.NotEqual(encrypted1, encrypted2);
    }

    [Fact]
    public async Task EncryptAsync_EmptyString_ReturnsSameEmptyString()
    {
        // Empty PHI fields should not be encrypted (no KMS call needed)
        var result = await _sut.EncryptAsync(string.Empty);
        Assert.Equal(string.Empty, result);
        _kmsMock.Verify(k => k.GenerateDataKeyAsync(
            It.IsAny<GenerateDataKeyRequest>(),
            It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task EncryptDecrypt_RoundTrip_ReturnOriginalPlaintext()
    {
        // This is the most important test: encrypt then decrypt must return original
        const string original = "Patricia Contreras";

        var encrypted = await _sut.EncryptAsync(original);
        var decrypted = await _sut.DecryptAsync(encrypted);

        Assert.Equal(original, decrypted);
    }

    [Fact]
    public async Task DecryptAsync_NonEncryptedValue_ReturnsSameValue()
    {
        // Values that don't have the 3-part format are returned as-is
        // (backward compatibility with non-encrypted legacy data)
        const string nonEncrypted = "plaintext-value";

        var result = await _sut.DecryptAsync(nonEncrypted);

        Assert.Equal(nonEncrypted, result);
        _kmsMock.Verify(k => k.DecryptAsync(
            It.IsAny<DecryptRequest>(),
            It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task EncryptAsync_CallsKms_WithCorrectEncryptionContext()
    {
        // Verify the KMS call includes the expected encryption context
        // (binding the DEK to this specific service and purpose)
        await _sut.EncryptAsync("test-phi-value");

        _kmsMock.Verify(k => k.GenerateDataKeyAsync(
            It.Is<GenerateDataKeyRequest>(r =>
                r.KeyId == FakeKmsKeyId &&
                r.EncryptionContext["service"] == "patient-service" &&
                r.EncryptionContext["purpose"] == "phi-encryption"),
            It.IsAny<CancellationToken>()), Times.Once);
    }

    private static bool IsValidBase64(string s)
    {
        try { Convert.FromBase64String(s); return true; }
        catch { return false; }
    }
}
