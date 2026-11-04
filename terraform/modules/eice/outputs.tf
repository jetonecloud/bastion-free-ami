output "enabled" {
  description = "Whether the endpoint was actually created. False when either enabled or i_understand_this_reintroduces_ssh is false."
  value       = local.create
}

output "endpoint_id" {
  description = "ID of the EC2 Instance Connect Endpoint, or empty when not created."
  value       = local.create ? aws_ec2_instance_connect_endpoint.this[0].id : ""
}

output "endpoint_arn" {
  description = "ARN of the endpoint, or empty when not created."
  value       = local.create ? aws_ec2_instance_connect_endpoint.this[0].arn : ""
}

output "endpoint_dns_name" {
  description = "DNS name of the endpoint, or empty when not created."
  value       = local.create ? aws_ec2_instance_connect_endpoint.this[0].dns_name : ""
}

output "security_group_id" {
  description = "ID of the endpoint security group. Reference THIS in the target host's inbound rule rather than a CIDR -- it is tighter and survives re-addressing."
  value       = local.create && var.create_security_group ? aws_security_group.eice[0].id : ""
}

output "iam_policy_arn" {
  description = "ARN of the OpenTunnel policy, or empty when not created."
  value       = local.create && var.create_iam_policy ? aws_iam_policy.open_tunnel[0].arn : ""
}

output "required_target_security_group_rule" {
  description = "The inbound rule you must add to each TARGET host's security group. This module deliberately does not create it: the rule belongs to a security group this module does not own, and a module named 'eice' should not quietly open port 22 on somebody else's host."
  value = local.create ? {
    hcl = join("\n", [
      "resource \"aws_vpc_security_group_ingress_rule\" \"ssh_from_eice\" {",
      "  security_group_id            = <YOUR TARGET SECURITY GROUP ID>",
      "  description                  = \"SSH from EC2 Instance Connect Endpoint\"",
      "  ip_protocol                  = \"tcp\"",
      "  from_port                    = 22",
      "  to_port                      = 22",
      "  referenced_security_group_id = \"${var.create_security_group ? aws_security_group.eice[0].id : "<endpoint security group>"}\"",
      "}",
    ])
    warning = "Adding this rule gives the target host an inbound path on port 22. It is narrower than a public bastion -- the source is an AWS-managed endpoint, not the internet -- but it is a real inbound rule, and scripts/verify will report it as one."
  } : null
}

output "connect_commands" {
  description = "Example commands for using the endpoint."
  value = local.create ? {
    ssh_single = "ssh -i <key.pem> ec2-user@<instance-id> -o ProxyCommand='aws ec2-instance-connect open-tunnel --instance-id %h'"
    tunnel = join(" ", compact([
      "aws ec2-instance-connect open-tunnel",
      "--region ${local.region}",
      "--instance-id <instance-id>",
      "--local-port <local-port>",
      "--remote-port ${var.iam_allowed_remote_ports[0]}",
      var.iam_max_tunnel_duration_seconds > 0 ? "--max-tunnel-duration ${var.iam_max_tunnel_duration_seconds}" : "",
    ]))
    note = var.iam_max_tunnel_duration_seconds > 0 ? "Because maxTunnelDuration is conditioned in IAM, callers MUST pass --max-tunnel-duration or AWS returns AccessDeniedException." : "No maxTunnelDuration condition is set."
  } : null
}

output "limitations" {
  description = "What EICE does and does not give you, as data, so a security review can quote it rather than restate it."
  value = {
    reintroduces_inbound_ssh  = "The target host's security group must allow inbound TCP 22 from this endpoint. That is an inbound rule on port 22, which the rest of this kit exists to remove."
    cannot_target_access_node = "The access node's sshd is masked and its security group has no inbound rules, so a tunnel to it reaches nothing. Use Session Manager for the access node; this module is for other hosts that genuinely require SSH."
    traffic_not_logged        = "Tunnel contents are not captured. CloudTrail records the OpenTunnel call -- principal, instance, port, time -- not what passed through the tunnel."
    iam_scoping_is_real       = "Unlike Session Manager port forwarding, ec2-instance-connect:OpenTunnel honours the remotePort, privateIpAddress, and maxTunnelDuration condition keys, so destination and port allowlists are enforced by IAM itself."
    key_management_returns    = "You are managing an SSH key again, or relying on EC2 Instance Connect's ephemeral key push, which requires the ec2-instance-connect package on the target."
  }
}
