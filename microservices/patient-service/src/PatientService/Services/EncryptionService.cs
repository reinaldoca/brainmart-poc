// ─────────────────────────────────────────────────────────────────────────────
// Services/EncryptionService.cs
//
// KMS Envelope Encryption para campos PHI (Protected Health Information)
//
// ESTRATEGIA ENVELOPE ENCRYPTION:
//   1. KMS genera una DEK (Data Encryption Key) de 256 bits
//   2. La DEK cifra el campo PHI con AES-256-GCM
//   3. KMS cifra la DEK con la CMK (Customer Managed Key)
//   4. En BD se guarda: encrypted_field = base64(encrypted_dek + nonce + ciphertext)
//
// Para DESCIFRAR:
//   1. Extraer encrypted_dek del campo
//   2. KMS descifra la encrypted_dek → DEK en plano (solo en memoria)
//   3. DEK descifra el ciphertext
//   4. DEK se descarta (no se almacena en ningún lado)
//
// VENTAJA vs cifrado directo con KMS:
//   - KMS no tiene límite de throughput de datos (solo opera con la DEK pequeña)
//   - El acceso a la CMK está auditado en CloudTrail
//   - Si se revoca la CMK, todos los datos quedan inaccesibles (para GDPR)
// ─────────────────────────────────────────────────────────────────────────────

using Amazon.KeyManagementService;
using Amazon.KeyManagementService.Model;
using System.Security.Cryptography;
using System.Text;

namespace PatientService.Services;

public interface IEncryptionService
{
    Task<string> EncryptAsync(string plaintext);
    Task<string> DecryptAsync(string ciphertext);
}

public class KmsEncryptionService : IEncryptionService
{
    private readonly IAmazonKeyManagementService _kmsClient;
    private readonly string _kmsKeyId;
    private readonly ILogger<KmsEncryptionService> _logger;

    // Separador entre las partes del campo cifrado
    private const string SEPARATOR = ".";

    public KmsEncryptionService(
        IAmazonKeyManagementService kmsClient,
        IConfiguration configuration,
        ILogger<KmsEncryptionService> logger)
    {
        _kmsClient = kmsClient;
        _kmsKeyId  = configuration["KMS:KeyId"]
            ?? throw new InvalidOperationException("KMS:KeyId not configured");
        _logger    = logger;
    }

    /// <summary>
    /// Cifra un campo PHI con KMS Envelope Encryption.
    /// Retorna: base64(encryptedDek).base64(nonce).base64(ciphertext)
    /// </summary>
    public async Task<string> EncryptAsync(string plaintext)
    {
        if (string.IsNullOrEmpty(plaintext))
            return plaintext;

        try
        {
            // PASO 1: Generar DEK con KMS
            var generateKeyRequest = new GenerateDataKeyRequest
            {
                KeyId   = _kmsKeyId,
                KeySpec = DataKeySpec.AES_256,
                // Context de cifrado: vincula la DEK a este contexto específico
                // Si el context cambia, la DEK no se puede usar (seguridad adicional)
                EncryptionContext = new Dictionary<string, string>
                {
                    ["service"] = "patient-service",
                    ["purpose"] = "phi-encryption"
                }
            };

            var keyResponse = await _kmsClient.GenerateDataKeyAsync(generateKeyRequest);

            // keyResponse.Plaintext = DEK en plano (para cifrar el dato)
            // keyResponse.CiphertextBlob = DEK cifrada por KMS (para guardar en BD)

            // PASO 2: Cifrar el dato con la DEK usando AES-256-GCM
            var nonce      = RandomNumberGenerator.GetBytes(12);  // 96 bits para GCM
            var plaintextBytes = Encoding.UTF8.GetBytes(plaintext);

            using var aes = new AesGcm(keyResponse.Plaintext.ToArray(), AesGcm.TagByteSizes.MaxSize);
            var ciphertext = new byte[plaintextBytes.Length];
            var tag        = new byte[AesGcm.TagByteSizes.MaxSize];

            aes.Encrypt(nonce, plaintextBytes, ciphertext, tag);

            // PASO 3: Limpiar la DEK en plano de la memoria inmediatamente
            keyResponse.Plaintext.GetBuffer().AsSpan().Clear();

            // Combinar ciphertext + tag (GCM tag para integridad)
            var ciphertextWithTag = new byte[ciphertext.Length + tag.Length];
            ciphertext.CopyTo(ciphertextWithTag, 0);
            tag.CopyTo(ciphertextWithTag, ciphertext.Length);

            // PASO 4: Serializar: encryptedDek.nonce.ciphertextWithTag
            return string.Join(SEPARATOR,
                Convert.ToBase64String(keyResponse.CiphertextBlob.ToArray()),
                Convert.ToBase64String(nonce),
                Convert.ToBase64String(ciphertextWithTag));
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error cifrando campo PHI con KMS");
            throw;
        }
    }

    /// <summary>Descifra un campo PHI previamente cifrado con EncryptAsync.</summary>
    public async Task<string> DecryptAsync(string encryptedValue)
    {
        if (string.IsNullOrEmpty(encryptedValue))
            return encryptedValue;

        // Si el valor no tiene el formato esperado, asumimos que no está cifrado
        var parts = encryptedValue.Split(SEPARATOR);
        if (parts.Length != 3)
            return encryptedValue;

        try
        {
            var encryptedDek      = Convert.FromBase64String(parts[0]);
            var nonce             = Convert.FromBase64String(parts[1]);
            var ciphertextWithTag = Convert.FromBase64String(parts[2]);

            // PASO 1: Descifrar la DEK con KMS
            var decryptRequest = new DecryptRequest
            {
                CiphertextBlob = new MemoryStream(encryptedDek),
                EncryptionContext = new Dictionary<string, string>
                {
                    ["service"] = "patient-service",
                    ["purpose"] = "phi-encryption"
                }
            };

            var decryptResponse = await _kmsClient.DecryptAsync(decryptRequest);

            // PASO 2: Descifrar el dato con la DEK
            var tagSize    = AesGcm.TagByteSizes.MaxSize;
            var ciphertext = ciphertextWithTag[..^tagSize];
            var tag        = ciphertextWithTag[^tagSize..];
            var plaintext  = new byte[ciphertext.Length];

            using var aes = new AesGcm(decryptResponse.Plaintext.ToArray(), tagSize);
            aes.Decrypt(nonce, ciphertext, tag, plaintext);

            // PASO 3: Limpiar la DEK
            decryptResponse.Plaintext.GetBuffer().AsSpan().Clear();

            return Encoding.UTF8.GetString(plaintext);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error descifrando campo PHI con KMS");
            throw;
        }
    }
}
