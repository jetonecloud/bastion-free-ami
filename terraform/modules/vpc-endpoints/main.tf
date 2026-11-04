data "aws_region" "current" {}

# ---------------------------------------------------------------------
# VPC endpoints for a fully private access node, with no NAT gateway.
#
# Which endpoints are actually required, per current AWS documentation:
#
#   ssm          required -- the Systems Manager service endpoint
#   ssmmessages  required -- Session Manager's data channel
#   s3 (gateway) required -- SSM Agent updates itself from S3; free
#   kms          when session data is KMS-encrypted
#   logs         when shipping session or OS logs
#   ec2messages  legacy; superseded by ssmmessages from agent 3.3.40.0
#   ec2          only for VSS-enabled snapshots, which this kit does not use
#
# Deliberately NOT created: sts, ecr, secretsmanager. Nothing in the
# access path calls them. Add them in your own configuration if your
# workloads need them -- each interface endpoint is billed per AZ per
# hour, and a module that creates endpoints nobody uses is a bill with
# no owner.
#
# Cost note: three interface endpoints across two AZs costs less than a
# single NAT gateway, and removes egress to the internet entirely. That
# is why the private-subnets example is both the most secure and the
# cheapest configuration in this repo.
# ---------------------------------------------------------------------
locals {
  region = data.aws_region.current.region

  interface_endpoints = {
    for k, v in {
      ssm         = var.enable_ssm_endpoint
      ssmmessages = var.enable_ssmmessages_endpoint
      ec2messages = var.enable_ec2messages_endpoint
      kms         = var.enable_kms_endpoint
      logs        = var.enable_logs_endpoint
      ec2         = var.enable_ec2_endpoint
    } : k => v if v
  }

  security_group_ids = (
    var.create_security_group
    ? [aws_security_group.endpoints[0].id]
    : var.endpoint_security_group_ids
  )

  tags = merge(
    {
      Project   = "bastion-free-ami"
      Module    = "vpc-endpoints"
      ManagedBy = "terraform"
    },
    var.tags
  )
}

resource "terraform_data" "preconditions" {
  input = var.name

  lifecycle {
    # Without ssmmessages there is no data channel and Session Manager
    # cannot establish a session at all. Failing here beats debugging a
    # TargetNotConnected error later.
    precondition {
      condition     = var.enable_ssmmessages_endpoint || var.enable_ec2messages_endpoint
      error_message = "enable_ssmmessages_endpoint must be true (or enable_ec2messages_endpoint for pre-3.3.40.0 agents). Session Manager cannot establish a session without a messages endpoint, and in a no-NAT subnet there is no fallback path."
    }

    precondition {
      condition     = !var.enable_ssmmessages_endpoint || var.enable_ssm_endpoint
      error_message = "enable_ssm_endpoint must be true: the agent calls ssm:UpdateInstanceInformation to register, and an unregistered node is not a valid Session Manager target."
    }

    precondition {
      condition     = !var.enable_s3_endpoint || length(var.route_table_ids) > 0
      error_message = "enable_s3_endpoint = true requires route_table_ids. A gateway endpoint grants access by adding routes, so one not associated with your subnets' route tables does nothing."
    }

    precondition {
      condition     = var.create_security_group || length(var.endpoint_security_group_ids) > 0
      error_message = "Set create_security_group = true, or pass endpoint_security_group_ids. Interface endpoints with no security group allowing inbound 443 are unreachable."
    }

    precondition {
      condition     = !var.create_security_group || length(var.access_node_security_group_ids) > 0 || var.vpc_cidr_block != ""
      error_message = "Pass access_node_security_group_ids (preferred) or vpc_cidr_block, so the endpoint security group knows what to allow inbound on 443."
    }

    precondition {
      condition     = var.private_dns_enabled
      error_message = "private_dns_enabled = false means SSM Agent keeps resolving the public service hostname, so these endpoints are paid for and unused. If you genuinely manage DNS yourself, fork the module rather than disabling this silently."
    }
  }
}

# ---------------------------------------------------------------------
# Endpoint security group.
#
# AWS documents that the endpoint's security group must allow inbound
# 443 from the managed instance's subnet, or the instance cannot reach
# the SSM and EC2 endpoints. Note this inbound rule is on the ENDPOINT,
# not on the access node -- the node still has none.
# ---------------------------------------------------------------------
resource "aws_security_group" "endpoints" {
  count = var.create_security_group ? 1 : 0

  name_prefix = "${var.name}-endpoints-"
  description = "bastion-free-ami: HTTPS from access nodes to the SSM interface endpoints"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${var.name}-endpoints-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# Preferred: reference the access node security group, so the rule stays
# correct if the VPC is ever re-addressed.
resource "aws_vpc_security_group_ingress_rule" "from_access_nodes" {
  for_each = var.create_security_group ? toset(var.access_node_security_group_ids) : toset([])

  security_group_id = aws_security_group.endpoints[0].id
  description       = "HTTPS from access nodes"

  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = each.value
}

# Fallback when no security group was supplied.
resource "aws_vpc_security_group_ingress_rule" "from_vpc_cidr" {
  count = var.create_security_group && length(var.access_node_security_group_ids) == 0 && var.vpc_cidr_block != "" ? 1 : 0

  security_group_id = aws_security_group.endpoints[0].id
  description       = "HTTPS from within the VPC"

  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
  cidr_ipv4   = var.vpc_cidr_block
}

# ---------------------------------------------------------------------
# Interface endpoints
# ---------------------------------------------------------------------
resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${local.region}.${each.key}"
  vpc_endpoint_type = "Interface"

  subnet_ids          = var.subnet_ids
  security_group_ids  = local.security_group_ids
  private_dns_enabled = var.private_dns_enabled

  policy = var.endpoint_policy_json != "" ? var.endpoint_policy_json : null

  tags = merge(local.tags, { Name = "${var.name}-${each.key}" })
}

# ---------------------------------------------------------------------
# S3 gateway endpoint.
#
# Gateway rather than interface: it is free, and SSM Agent only needs S3
# for its own updates. A gateway endpoint works by injecting routes, so
# it must be associated with the route tables your subnets use.
# ---------------------------------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  count = var.enable_s3_endpoint ? 1 : 0

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = var.route_table_ids

  tags = merge(local.tags, { Name = "${var.name}-s3" })
}
