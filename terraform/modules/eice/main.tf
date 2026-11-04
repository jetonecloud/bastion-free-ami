data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# ---------------------------------------------------------------------
# EC2 Instance Connect Endpoint. OFF BY DEFAULT.
#
# WHEN THIS IS JUSTIFIED
#
# Exactly one situation: a tool that must speak real SSH. rsync, scp,
# `ssh -D`, an IDE remote-development plugin, or an appliance that only
# knows SSH. Session Manager's AWS-StartSSHSession can also do this, but
# EICE does it without an SSM Agent on the target.
#
# WHAT IT COSTS, stated plainly
#
#   1. It reintroduces SSH on the TARGET. The target's security group
#      must allow inbound TCP 22 from the endpoint (or its security
#      group). That is an inbound rule, on port 22, on a host this kit
#      otherwise guarantees has neither. It is narrower than a public
#      bastion -- the source is an AWS-managed endpoint rather than the
#      internet -- but it is a real inbound path.
#
#   2. Key management comes back. You are managing an SSH key again, or
#      relying on EC2 Instance Connect's ephemeral key push.
#
#   3. Tunnel contents are not logged, the same gap as Session Manager
#      port forwarding. CloudTrail records the OpenTunnel call -- who,
#      which instance, which port, when -- not what went through it.
#
# WHAT IT DOES BETTER THAN SESSION MANAGER
#
# IAM scoping, genuinely. ec2-instance-connect:OpenTunnel honours the
# condition keys remotePort, privateIpAddress, and maxTunnelDuration. So
# unlike port forwarding -- where IAM cannot see the host or port at all
# -- you really can allowlist destination and port in the policy itself.
# The iam_* variables map one-to-one onto those keys.
#
# NOTE: EICE CANNOT TARGET THE ACCESS NODE
#
# The access node's sshd is masked and its security group has no inbound
# rules, so a tunnel to it would connect to nothing. This module is for
# OTHER hosts in the VPC that genuinely need SSH. Reaching the access
# node is what Session Manager is for.
# ---------------------------------------------------------------------
locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  create = var.enabled && var.i_understand_this_reintroduces_ssh

  security_group_ids = (
    var.create_security_group && local.create
    ? [aws_security_group.eice[0].id]
    : var.security_group_ids
  )

  tags = merge(
    {
      Project   = "bastion-free-ami"
      Module    = "eice"
      ManagedBy = "terraform"
      # Tagged so an audit of "what reintroduced SSH" has an answer.
      ReintroducesInboundSsh = "true"
    },
    var.tags
  )
}

resource "terraform_data" "preconditions" {
  input = var.name

  lifecycle {
    precondition {
      condition     = !var.enabled || var.i_understand_this_reintroduces_ssh
      error_message = "enabled = true also requires i_understand_this_reintroduces_ssh = true. An EC2 Instance Connect Endpoint only works if the target host accepts inbound SSH from it, which means adding an inbound rule on port 22 to a host this kit otherwise guarantees has none. Read terraform/modules/eice/README.md and decide deliberately."
    }

    precondition {
      condition     = !local.create || var.subnet_id != ""
      error_message = "subnet_id is required when the endpoint is enabled."
    }

    precondition {
      condition     = !local.create || !var.create_security_group || var.vpc_id != ""
      error_message = "vpc_id is required when create_security_group is true."
    }

    precondition {
      condition     = !local.create || !var.create_security_group || length(var.target_cidr_blocks) > 0
      error_message = "target_cidr_blocks is required so the endpoint's egress is limited to the subnets holding hosts that actually need SSH. Passing the whole VPC defeats the point of using an endpoint over a bastion."
    }
  }
}

resource "aws_ec2_instance_connect_endpoint" "this" {
  count = local.create ? 1 : 0

  subnet_id          = var.subnet_id
  security_group_ids = local.security_group_ids

  # Defaults to false here, against the AWS default of true, so that
  # target security groups can reference this endpoint's security group
  # instead of an unpredictable client IP range. Referencing a group is
  # both simpler to write and tighter than any CIDR you could guess.
  preserve_client_ip = var.preserve_client_ip

  tags = merge(local.tags, { Name = var.name })
}

# ---------------------------------------------------------------------
# Endpoint security group.
#
# Egress only: the endpoint initiates connections to targets. Reference
# this group in the TARGET's inbound rule:
#
#   resource "aws_vpc_security_group_ingress_rule" "ssh_from_eice" {
#     security_group_id            = <target sg>
#     ip_protocol                  = "tcp"
#     from_port                    = 22
#     to_port                      = 22
#     referenced_security_group_id = module.eice.security_group_id
#   }
#
# That rule is deliberately NOT created here. It belongs to the target's
# security group, which this module does not own, and creating it
# implicitly would mean a module called "eice" quietly opening port 22
# on somebody else's host.
# ---------------------------------------------------------------------
resource "aws_security_group" "eice" {
  count = local.create && var.create_security_group ? 1 : 0

  name_prefix = "${var.name}-"
  description = "bastion-free-ami EC2 Instance Connect Endpoint: egress to SSH targets only"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${var.name}-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "to_targets" {
  for_each = local.create && var.create_security_group ? {
    for pair in setproduct(var.target_cidr_blocks, var.allowed_ports) :
    "${pair[0]}-${pair[1]}" => { cidr = pair[0], port = pair[1] }
  } : {}

  security_group_id = aws_security_group.eice[0].id
  description       = "Tunnel to port ${each.value.port} on ${each.value.cidr}"

  ip_protocol = "tcp"
  from_port   = each.value.port
  to_port     = each.value.port
  cidr_ipv4   = each.value.cidr
}

# ---------------------------------------------------------------------
# IAM policy for callers.
#
# This is where EICE earns its place: the conditions below are real,
# enforced-by-IAM allowlists on destination port and IP, which Session
# Manager port forwarding cannot offer.
# ---------------------------------------------------------------------
data "aws_iam_policy_document" "open_tunnel" {
  count = local.create && var.create_iam_policy ? 1 : 0

  statement {
    sid    = "OpenTunnelToAllowedTargets"
    effect = "Allow"

    actions = ["ec2-instance-connect:OpenTunnel"]

    # Scoped to this specific endpoint, so the policy cannot be used
    # with some other endpoint created later.
    resources = [aws_ec2_instance_connect_endpoint.this[0].arn]

    # Real IAM enforcement of destination port.
    condition {
      test     = "NumericEquals"
      variable = "ec2-instance-connect:remotePort"
      values   = [for p in var.iam_allowed_remote_ports : tostring(p)]
    }

    # Real IAM enforcement of destination address.
    dynamic "condition" {
      for_each = length(var.iam_allowed_private_ip_cidrs) > 0 ? [1] : []

      content {
        test     = "IpAddress"
        variable = "ec2-instance-connect:privateIpAddress"
        values   = var.iam_allowed_private_ip_cidrs
      }
    }

    # Caps how long a tunnel may stay open. Callers must then pass
    # --max-tunnel-duration, or AWS returns AccessDeniedException.
    dynamic "condition" {
      for_each = var.iam_max_tunnel_duration_seconds > 0 ? [1] : []

      content {
        test     = "NumericLessThanEquals"
        variable = "ec2-instance-connect:maxTunnelDuration"
        values   = [tostring(var.iam_max_tunnel_duration_seconds)]
      }
    }
  }

  # Needed to resolve an instance ID to its private IP before tunnelling.
  # Resource "*" because DescribeInstances is a list operation that
  # accepts no resource ARN. Read-only.
  statement {
    sid       = "DescribeInstancesForTunnelTargeting"
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  # Optional tag scoping on the target instance.
  dynamic "statement" {
    for_each = var.iam_target_tag_key != "" ? [1] : []

    content {
      sid       = "DenyUntaggedTargets"
      effect    = "Deny"
      actions   = ["ec2-instance-connect:OpenTunnel"]
      resources = ["*"]

      condition {
        test     = "StringNotEquals"
        variable = "aws:ResourceTag/${var.iam_target_tag_key}"
        values   = [var.iam_target_tag_value]
      }
    }
  }
}

resource "aws_iam_policy" "open_tunnel" {
  count = local.create && var.create_iam_policy ? 1 : 0

  name_prefix = "${var.name}-"
  description = "bastion-free-ami: EC2 Instance Connect Endpoint tunnel access, scoped by port and destination IP. NOTE: this grants SSH reachability to the permitted targets."
  policy      = data.aws_iam_policy_document.open_tunnel[0].json

  tags = local.tags
}
