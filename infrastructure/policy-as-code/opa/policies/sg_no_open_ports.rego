# ──────────────────────────────────────────────────────────────────────────────
# infrastructure/policy-as-code/opa/policies/sg_no_open_ports.rego
#
# POLÍTICA OPA: Security Groups no deben tener 0.0.0.0/0 en puertos críticos
#
# PUERTOS PROTEGIDOS:
#   22   → SSH: acceso directo a servidores (usar Systems Manager Session Manager)
#   5432 → PostgreSQL: base de datos de pacientes
#   3306 → MySQL: base de datos alternativa
#   1433 → SQL Server: base de datos Windows
#   3389 → RDP: acceso remoto Windows (también bloqueado por precaución)
#
# COMPLEMENTA: SCP scp-prohibit-open-ports.json de Capa 0
# La SCP previene en AWS; esta policy detecta en el plan de Terraform (Shift-Left)
# ──────────────────────────────────────────────────────────────────────────────

package brainmart.security_groups

import future.keywords.in
import future.keywords.if

# ── Puertos sensibles que NUNCA deben estar abiertos a internet ──
sensitive_ports := {22, 5432, 3306, 1433, 3389}

# ── CIDRs que representan "toda internet" ──
open_cidrs := {"0.0.0.0/0", "::/0"}

# ── REGLA PRINCIPAL: deny ──

# Regla: Security Groups NO deben tener 0.0.0.0/0 en puertos sensibles (ingress)
deny contains msg if {
    some resource in input.resource_changes

    resource.type == "aws_security_group"
    resource.change.actions[_] in {"create", "update"}

    config := resource.change.after

    # Recorrer todas las reglas de ingress
    some rule in config.ingress

    # Verificar si algún CIDR es abierto
    some cidr in rule.cidr_blocks
    cidr in open_cidrs

    # Verificar si el puerto es sensible
    is_sensitive_port(rule)

    msg := sprintf(
        "❌ [Security Group] Security Group '%s' tiene una regla de ingress con CIDR %s " +
        "en el puerto %d-%d (protocolo: %s). " +
        "Este puerto es sensible y no debe ser accesible desde internet. " +
        "Puertos sensibles: %v. " +
        "Alternativas: Systems Manager Session Manager (SSH), VPN (DB access).",
        [
            resource.address,
            cidr,
            rule.from_port,
            rule.to_port,
            rule.protocol,
            sensitive_ports
        ]
    )
}

# Regla: Security Groups NO deben tener ::/0 en puertos sensibles (IPv6)
deny contains msg if {
    some resource in input.resource_changes

    resource.type == "aws_security_group"
    resource.change.actions[_] in {"create", "update"}

    config := resource.change.after

    some rule in config.ingress

    # Verificar IPv6
    some cidr in rule.ipv6_cidr_blocks
    cidr in open_cidrs

    is_sensitive_port(rule)

    msg := sprintf(
        "❌ [Security Group IPv6] Security Group '%s' tiene una regla de ingress con CIDR IPv6 %s " +
        "en el puerto %d (sensible). Los puertos de BD/SSH no deben ser accesibles desde internet.",
        [resource.address, cidr, rule.from_port]
    )
}

# Regla: aws_security_group_rule tampoco debe tener puertos sensibles abiertos
deny contains msg if {
    some resource in input.resource_changes

    resource.type == "aws_security_group_rule"
    resource.change.actions[_] in {"create", "update"}

    config := resource.change.after

    config.type == "ingress"

    some cidr in config.cidr_blocks
    cidr in open_cidrs

    is_sensitive_port_rule(config)

    msg := sprintf(
        "❌ [Security Group Rule] Regla de security group '%s' permite acceso desde %s " +
        "al puerto %d (sensible). Revisar y restringir a CIDRs específicos.",
        [resource.address, cidr, config.from_port]
    )
}

# Regla: No se permite ALL traffic (protocol = -1) desde internet
deny contains msg if {
    some resource in input.resource_changes

    resource.type == "aws_security_group"
    resource.change.actions[_] in {"create", "update"}

    config := resource.change.after

    some rule in config.ingress

    some cidr in rule.cidr_blocks
    cidr in open_cidrs

    # Protocolo -1 = todos los protocolos
    rule.protocol in {"-1", "all", -1}

    msg := sprintf(
        "❌ [Security Group All Traffic] Security Group '%s' permite TODO el tráfico " +
        "desde %s (protocolo: ALL). Esto viola el principio de mínimo privilegio. " +
        "Especificar puertos y protocolos exactos.",
        [resource.address, cidr]
    )
}

# ── FUNCIONES AUXILIARES ──

# Determina si una regla de ingress afecta un puerto sensible
is_sensitive_port(rule) if {
    rule.from_port == 0
    rule.to_port == 0
    rule.protocol == "-1"  # ALL protocols
}

is_sensitive_port(rule) if {
    some port in sensitive_ports
    rule.from_port <= port
    rule.to_port >= port
}

# Para aws_security_group_rule
is_sensitive_port_rule(rule) if {
    some port in sensitive_ports
    rule.from_port <= port
    rule.to_port >= port
}

is_sensitive_port_rule(rule) if {
    rule.protocol in {"-1", "all", -1}
}

# ── REGLAS DE ADVERTENCIA ──

# Advertencia: el puerto 80 HTTP abierto (deberían usar HTTPS)
warn contains msg if {
    some resource in input.resource_changes

    resource.type == "aws_security_group"
    resource.change.actions[_] in {"create", "update"}

    config := resource.change.after

    some rule in config.ingress

    some cidr in rule.cidr_blocks
    cidr in open_cidrs

    rule.from_port <= 80
    rule.to_port >= 80

    msg := sprintf(
        "⚠️  [Security Group HTTP] Security Group '%s' tiene el puerto 80 (HTTP) abierto desde internet. " +
        "Considerar redirigir HTTP → HTTPS en el load balancer y solo exponer el puerto 443.",
        [resource.address]
    )
}
