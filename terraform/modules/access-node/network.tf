# ---------------------------------------------------------------------
# Security group: egress only.
#
# There is no ingress block, and no variable that could add one. Session
# Manager needs no inbound rule at all: SSM Agent on the node dials out
# to the ssmmessages endpoint and holds that channel open, and the
# service pushes work down it. An inbound rule here is precisely what
# this project exists to remove, so the module does not provide a way to
# create one. If you need inbound SSH on some other host, that is what
# terraform/modules/eice is for -- and it says what that costs.
# ---------------------------------------------------------------------
resource "aws_security_group" "access_node" {
  count = var.create_security_group ? 1 : 0

  name_prefix = "${var.name}-"
  description = "bastion-free-ami access node: egress only, no inbound rules (Session Manager requires none)"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${var.name}-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# HTTPS to the AWS APIs: ssm, ssmmessages, and (when logging is on) logs,
# kms, and s3. This is the only egress the access path itself needs.
resource "aws_vpc_security_group_egress_rule" "aws_apis" {
  count = var.create_security_group ? 1 : 0

  security_group_id = aws_security_group.access_node[0].id
  description       = "HTTPS to AWS APIs (SSM control/data channel, CloudWatch Logs, KMS, S3)"

  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
  cidr_ipv4   = "0.0.0.0/0"
}

# Everything the node is expected to forward to. Deliberately broad by
# default -- a node that cannot reach your datastores is useless, and
# guessing your RDS port here would break more than it protected. Narrow
# egress_cidr_blocks to your VPC CIDR once you know what you forward to.
#
# Note what this does and does not control: it limits where the NODE can
# connect, which is a genuine containment boundary if the node is ever
# compromised. It does not limit which of those destinations a given
# TEAM may reach -- that is done with per-target session documents in
# access-iam, because IAM cannot condition on port-forwarding
# parameters. See docs/design.md.
resource "aws_vpc_security_group_egress_rule" "forward_targets" {
  for_each = var.create_security_group ? toset(var.egress_cidr_blocks) : toset([])

  security_group_id = aws_security_group.access_node[0].id
  description       = "Forwarding targets reachable from this access node"

  ip_protocol = "-1"
  cidr_ipv4   = each.value
}
