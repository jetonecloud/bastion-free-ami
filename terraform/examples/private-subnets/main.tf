# ---------------------------------------------------------------------
# private-subnets: no NAT gateway, no internet gateway, no egress.
#
# This is the configuration to aim for. The VPC has no route to the
# internet at all: access nodes reach Systems Manager exclusively
# through interface endpoints, so there is no path out of the subnet for
# an attacker to exfiltrate over, and no NAT gateway bill.
#
# It is also cheaper than the minimal example. Four interface endpoints
# across two AZs costs roughly $58/month; a single NAT gateway is ~$33
# plus data processing, and you usually end up running one per AZ. With
# the S3 gateway endpoint being free, the gap narrows further for any
# real workload.
#
# The trade-off: anything the access node needs must have an endpoint.
# There is no NAT to fall back on, so a missing endpoint is an outage
# rather than a slow path. That is why the vpc-endpoints module has
# preconditions instead of silent defaults.
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
    Example     = "private-subnets"
    Environment = var.environment
  }
}

# ---------------------------------------------------------------------
# Network: private only. Note the absence of an aws_internet_gateway,
# an aws_nat_gateway, and any 0.0.0.0/0 route.
# ---------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  # Both required for interface endpoint private DNS to work. Without
  # them the endpoints resolve to nothing and the nodes are unreachable.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = "${var.name}-vpc" })
}

resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, { Name = "${var.name}-private-${local.azs[count.index]}" })
}

# No default route. Traffic reaches AWS services via the endpoints
# below, and nothing else leaves the VPC.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = "${var.name}-private" })
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------
# The kit
# ---------------------------------------------------------------------
data "aws_ssm_parameter" "access_node_ami" {
  name = "/bastion-free-ami/${var.region}/latest"
}

module "session_logging" {
  source = "../../modules/session-logging"

  name = var.name

  enable_cloudwatch_logs    = true
  cloudwatch_retention_days = 365

  # S3 archive on, for longer retention and Athena queries. See
  # docs/queries/ for the table definition.
  enable_s3_archive         = true
  s3_archive_retention_days = 730

  custom_preferences_document_name = "${var.name}-SessionManagerRunShell"

  idle_session_timeout_minutes = 15
  max_session_duration_minutes = 240

  # The access node will not halt on a full audit partition, so alarm
  # on disk pressure instead. See docs/design.md.
  create_audit_disk_alarm = true

  tags = local.tags
}

module "access_node" {
  source = "../../modules/access-node"

  name   = "${var.name}-access-node"
  vpc_id = aws_vpc.this.id

  ami_id        = data.aws_ssm_parameter.access_node_ami.value
  instance_type = var.instance_type

  subnet_ids = aws_subnet.private[*].id

  min_size         = 1
  max_size         = 3
  desired_capacity = 2

  # With no internet egress, narrowing this to the VPC CIDR costs
  # nothing and bounds where a compromised node could connect.
  egress_cidr_blocks = [var.vpc_cidr]

  session_log_group_name    = module.session_logging.cloudwatch_log_group_name
  session_log_bucket_arn    = module.session_logging.s3_bucket_arn
  session_log_bucket_prefix = module.session_logging.s3_key_prefix
  session_kms_key_arn       = module.session_logging.kms_key_arn

  tags = local.tags
}

module "vpc_endpoints" {
  source = "../../modules/vpc-endpoints"

  name   = var.name
  vpc_id = aws_vpc.this.id

  # One endpoint ENI per AZ that runs access nodes. A node in an AZ with
  # no endpoint ENI cannot reach the service, and with no NAT there is
  # no fallback.
  subnet_ids      = aws_subnet.private[*].id
  route_table_ids = [aws_route_table.private.id]

  # Reference the node security group rather than a CIDR: tighter, and
  # it survives re-addressing the VPC.
  access_node_security_group_ids = [module.access_node.security_group_id]

  # Exactly what the access path needs.
  enable_ssm_endpoint         = true
  enable_ssmmessages_endpoint = true
  enable_s3_endpoint          = true # free; SSM Agent self-updates
  enable_kms_endpoint         = true # session data is KMS-encrypted
  enable_logs_endpoint        = true # session + OS logs

  # Legacy, superseded by ssmmessages from agent 3.3.40.0.
  enable_ec2messages_endpoint = false
  # Only needed for VSS-enabled snapshots, which this kit does not use.
  enable_ec2_endpoint = false

  tags = local.tags
}

module "access_iam" {
  source = "../../modules/access-iam"

  name = var.name

  access_tag_key        = module.access_node.access_tag_key
  session_document_name = module.session_logging.session_preferences_document_name
  session_kms_key_arn   = module.session_logging.kms_key_arn

  teams = {
    platform = {
      access_tag_value       = module.access_node.access_tag_value
      trusted_principal_arns = var.trusted_principal_arns
      allow_shell            = true
      require_mfa            = true
      max_mfa_age_seconds    = 3600
    }
  }

  tags = local.tags
}
