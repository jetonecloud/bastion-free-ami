# ---------------------------------------------------------------------
# minimal: one VPC with a NAT gateway.
#
# The simplest thing that works. Access nodes sit in private subnets and
# reach the Systems Manager endpoints through a NAT gateway.
#
# This is the example to read first, and the one to stop using once you
# have read terraform/examples/private-subnets -- which is both cheaper
# (three interface endpoints cost less than one NAT gateway) and more
# contained (no egress to the internet at all).
#
# Cost warning: the NAT gateway here is ~$33/month plus data
# processing, and is the dominant cost of this example by a wide margin.
# ---------------------------------------------------------------------
terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0.0, < 7.0.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  tags = {
    Project     = "bastion-free-ami"
    Example     = "minimal"
    Environment = var.environment
  }
}

# ---------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = "${var.name}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-igw" })
}

# Public subnets exist only to host the NAT gateway. No access node ever
# lands here -- the access-node module hardcodes
# associate_public_ip_address = false.
resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, { Name = "${var.name}-public-${local.azs[count.index]}" })
}

resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, { Name = "${var.name}-private-${local.azs[count.index]}" })
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = merge(local.tags, { Name = "${var.name}-nat" })
}

# A single NAT gateway, shared across AZs. Cheaper than one per AZ, at
# the cost of the access path depending on one AZ's NAT. Acceptable for
# this example; the private-subnets example avoids the question.
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.this]

  tags = merge(local.tags, { Name = "${var.name}-nat" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.tags, { Name = "${var.name}-public" })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = merge(local.tags, { Name = "${var.name}-private" })
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------
# The kit
# ---------------------------------------------------------------------

# The AMI published by the pipeline. Reading it from SSM rather than
# pinning an ID means `terraform apply` picks up the latest build, and
# the ASG's instance refresh rolls it out.
data "aws_ssm_parameter" "access_node_ami" {
  name = "/bastion-free-ami/${var.region}/latest"
}

module "session_logging" {
  source = "../../modules/session-logging"

  name = var.name

  enable_cloudwatch_logs    = true
  cloudwatch_retention_days = 365

  # Session preferences are account-and-region global. This example
  # creates a SEPARATELY NAMED document rather than touching the
  # account default, so running it cannot change behaviour for teams
  # that have nothing to do with this kit.
  custom_preferences_document_name = "${var.name}-SessionManagerRunShell"

  idle_session_timeout_minutes = 20
  max_session_duration_minutes = 240

  tags = local.tags
}

module "access_node" {
  source = "../../modules/access-node"

  name   = "${var.name}-access-node"
  vpc_id = aws_vpc.this.id

  ami_id        = data.aws_ssm_parameter.access_node_ami.value
  instance_type = var.instance_type

  # Private subnets across both AZs: losing an AZ costs capacity, not
  # access.
  subnet_ids = aws_subnet.private[*].id

  min_size         = 1
  max_size         = 2
  desired_capacity = 1

  # Session logging wiring. Passing these grants the instance role
  # write access scoped to exactly this log group and key.
  session_log_group_name = module.session_logging.cloudwatch_log_group_name
  session_kms_key_arn    = module.session_logging.kms_key_arn

  tags = local.tags
}

module "access_iam" {
  source = "../../modules/access-iam"

  name = var.name

  # Keep the tag key in sync with the access-node module by passing its
  # output, rather than repeating a string literal that can drift.
  access_tag_key        = module.access_node.access_tag_key
  session_document_name = module.session_logging.session_preferences_document_name
  session_kms_key_arn   = module.session_logging.kms_key_arn

  teams = {
    platform = {
      access_tag_value       = module.access_node.access_tag_value
      trusted_principal_arns = var.trusted_principal_arns

      # Shell on the access node, fully logged.
      allow_shell = true

      # No forward_targets in this example; see the multi-team example
      # for per-target allowlists.
    }
  }

  tags = local.tags
}
