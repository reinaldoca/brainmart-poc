# ??????????????????????????????????????????????????????????????????????????????
# modules/network/outputs.tf
# Valores exportados por el mo?dulo de red
# Estos outputs son consumidos por los mo?dulos: database, compute, storage
# ??????????????????????????????????????????????????????????????????????????????

output "vpc_id" {
  description = "ID de la VPC creada"
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "CIDR block de la VPC (usado por otros SGs para permitir tra?fico interno)"
  value       = aws_vpc.main.cidr_block
}

output "vpc_arn" {
  description = "ARN de la VPC"
  value       = aws_vpc.main.arn
}

# ?? IDs de subnets (usados por otros mo?dulos) ??

output "public_subnet_ids" {
  description = "IDs de las subnets pu?blicas (para ALB)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs de las subnets privadas (para ECS Fargate)"
  value       = aws_subnet.private[*].id
}

output "isolated_subnet_ids" {
  description = "IDs de las subnets aisladas (para RDS PostgreSQL)"
  value       = aws_subnet.isolated[*].id
}

# ?? CIDRs de subnets (usados para configurar Security Groups) ??

output "public_subnet_cidrs" {
  description = "CIDRs de las subnets pu?blicas"
  value       = aws_subnet.public[*].cidr_block
}

output "private_subnet_cidrs" {
  description = "CIDRs de las subnets privadas"
  value       = aws_subnet.private[*].cidr_block
}

output "isolated_subnet_cidrs" {
  description = "CIDRs de las subnets aisladas"
  value       = aws_subnet.isolated[*].cidr_block
}

# ?? Security Groups (usados por mo?dulos que crean recursos en la VPC) ??

output "alb_security_group_id" {
  description = "ID del Security Group del ALB"
  value       = aws_security_group.alb.id
}

output "ecs_security_group_id" {
  description = "ID del Security Group de ECS Fargate"
  value       = aws_security_group.ecs.id
}

output "rds_security_group_id" {
  description = "ID del Security Group de RDS PostgreSQL"
  value       = aws_security_group.rds.id
}

output "vpc_endpoints_security_group_id" {
  description = "ID del Security Group de VPC Endpoints"
  value       = aws_security_group.vpc_endpoints.id
}

# ?? DB Subnet Group (usado por el mo?dulo database) ??

output "db_subnet_group_name" {
  description = "Nombre del DB Subnet Group para RDS (ya incluye las subnets aisladas)"
  value       = aws_db_subnet_group.main.name
}

# ?? VPC Endpoints (usados para verificar conectividad) ??

output "s3_endpoint_id" {
  description = "ID del VPC Gateway Endpoint para S3"
  value       = var.enable_vpc_endpoints && var.vpc_endpoints.s3 ? aws_vpc_endpoint.s3[0].id : null
}

output "secrets_manager_endpoint_id" {
  description = "ID del VPC Interface Endpoint para Secrets Manager"
  value       = var.enable_vpc_endpoints && var.vpc_endpoints.secrets_manager ? aws_vpc_endpoint.secrets_manager[0].id : null
}

# ?? IDs de Route Tables (usados para agregar rutas en mo?dulos adicionales) ??

output "public_route_table_id" {
  description = "ID de la Route Table pu?blica"
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "IDs de las Route Tables privadas"
  value       = aws_route_table.private[*].id
}

output "isolated_route_table_id" {
  description = "ID de la Route Table aislada"
  value       = aws_route_table.isolated.id
}

# ?? NAT Gateway IPs (para whitelisting en firewalls externos) ??

output "nat_public_ips" {
  description = "IPs pu?blicas de los NAT Gateways (para whitelist en APIs externas)"
  value       = aws_eip.nat[*].public_ip
}

# ?? Availability Zones usadas ??

output "availability_zones" {
  description = "Lista de Availability Zones donde se desplegaron las subnets"
  value       = var.availability_zones
}
