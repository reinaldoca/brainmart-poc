output "kms_key_arn"       { value = aws_kms_key.secrets.arn }
output "kms_key_id"        { value = aws_kms_key.secrets.key_id }
output "kms_alias"         { value = aws_kms_alias.secrets.name }
output "jwt_secret_arn"    { value = aws_secretsmanager_secret.jwt_signing_key.arn }
output "jwt_secret_name"   { value = aws_secretsmanager_secret.jwt_signing_key.name }
output "rotation_lambda_arn" { value = aws_lambda_function.rotation.arn }
