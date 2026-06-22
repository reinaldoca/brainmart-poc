# infrastructure/policy-as-code/opa/policies/sg_no_open_ports.rego
# OPA POLICY: Security Groups must not expose sensitive ports to the internet
#
# PROTECTED PORTS: 22 (SSH), 5432 (PostgreSQL), 3306 (MySQL), 1433 (MSSQL), 3389 (RDP)
# RATIONALE: Zero-trust network architecture + GDPR data protection

package brainmart.network

import rego.v1

# Ports that must never be open to the internet
sensitive_ports := {22, 5432, 3306, 1433, 3389}

# CIDRs representing "all internet"
open_cidrs := {"0.0.0.0/0", "::/0"}

# ---------------------------------------------------------------------------
# DENY rules
# ---------------------------------------------------------------------------

# IPv4: sensitive ports must not be open to 0.0.0.0/0 (ingress)
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_security_group"
    resource.change.actions[_] in {"create", "update"}
    config := resource.change.after
    some rule in config.ingress
    some cidr in rule.cidr_blocks
    cidr in open_cidrs
    some port in sensitive_ports
    rule.from_port <= port
    rule.to_port >= port
    msg := sprintf(
        "[Security Group] SG '%s' has ingress rule allowing CIDR %s on port %d-%d (protocol: %s). Sensitive ports must not be internet-accessible. Ports: %v. Use SSM Session Manager (SSH) or VPN (DB).",
        [resource.address, cidr, rule.from_port, rule.to_port, rule.protocol, sensitive_ports]
    )
}

# IPv6: sensitive ports must not be open to ::/0 (ingress)
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_security_group"
    resource.change.actions[_] in {"create", "update"}
    config := resource.change.after
    some rule in config.ingress
    some cidr in rule.ipv6_cidr_blocks
    cidr == "::/0"
    some port in sensitive_ports
    rule.from_port <= port
    rule.to_port >= port
    msg := sprintf(
        "[Security Group IPv6] SG '%s' has IPv6 ingress allowing %s on sensitive port %d. DB/SSH ports must not be internet-accessible.",
        [resource.address, cidr, rule.from_port]
    )
}

# aws_security_group_rule: sensitive port open to internet
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_security_group_rule"
    resource.change.actions[_] in {"create", "update"}
    config := resource.change.after
    config.type == "ingress"
    some cidr in config.cidr_blocks
    cidr in open_cidrs
    some port in sensitive_ports
    config.from_port <= port
    config.to_port >= port
    msg := sprintf(
        "[Security Group Rule] SG rule '%s' allows access from %s to sensitive port %d. Restrict to specific CIDRs.",
        [resource.address, cidr, config.from_port]
    )
}

# ALL traffic (protocol=-1) from internet is forbidden
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_security_group"
    resource.change.actions[_] in {"create", "update"}
    config := resource.change.after
    some rule in config.ingress
    some cidr in rule.cidr_blocks
    cidr in open_cidrs
    rule.protocol == "-1"
    msg := sprintf(
        "[Security Group All Traffic] SG '%s' allows ALL traffic from %s (protocol: ALL). Violates least-privilege. Specify exact ports and protocols.",
        [resource.address, cidr]
    )
}

# ---------------------------------------------------------------------------
# WARN rules
# ---------------------------------------------------------------------------

# Port 80 (HTTP) open to internet should be redirected to 443
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
        "[Security Group HTTP] SG '%s' has port 80 (HTTP) open from internet. Consider redirecting HTTP->HTTPS at the load balancer and only exposing port 443.",
        [resource.address]
    )
}