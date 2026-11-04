# ---------------------------------------------------------------------
# multi-team: separate team roles and per-target resource allowlists.
#
# Three teams, three different levels of access, one existing VPC:
#
#   payments   shell + forwarding to the payments database only
#   analytics  forwarding to the analytics warehouse and Redis, NO shell
#   platform   shell on every node, plus elevated access via Run As
#
# This example uses an EXISTING VPC rather than creating one, because by
# the time you have three teams you have a VPC already.
#
# It also demonstrates the thing people get wrong about Session Manager:
# per-team host and port allowlists cannot be done with IAM conditions,
# because IAM has no condition key for the host or portNumber parameters
# of ssm:StartSession. They are done by minting one Port session
# document per target, with the host and port as FIXED properties, and
# granting each team only its own documents. See docs/design.md.
#
# Note how analytics gets no shell: a team that only needs to query a
# warehouse has no reason to be able to run commands on the node.
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

locals {
  tags = {
    Project     = "bastion-free-ami"
    Example     = "multi-team"
    Environment = var.environment
  }
}

data "aws_vpc" "this" {
  id = var.vpc_id
}

data "aws_ssm_parameter" "access_node_ami" {
  name = "/bastion-free-ami/${var.region}/latest"
}

module "session_logging" {
  source = "../../modules/session-logging"

  name = var.name

  enable_cloudwatch_logs    = true
  cloudwatch_retention_days = 731 # two years, for a multi-team audit trail

  enable_s3_archive         = true
  s3_archive_retention_days = 2557 # seven years

  # A separately named document, NOT the account default. With three
  # teams in a shared account, taking over SSM-SessionManagerRunShell
  # would change session behaviour for everyone else in the account
  # too. This is the posture the module recommends.
  custom_preferences_document_name = "${var.name}-SessionManagerRunShell"

  idle_session_timeout_minutes = 15

  # Long enough for a legitimate tunnel: this also caps port-forwarding
  # sessions, and a four-hour cap on a database session that someone is
  # mid-migration on is its own kind of outage.
  max_session_duration_minutes = 480

  # Sessions run as a named unprivileged OS user. The platform team's
  # role is tagged SSMSessionRunAs to override this -- that is the
  # documented elevation path, and it is separately auditable because
  # the role itself is what carries the privilege.
  run_as_enabled      = true
  run_as_default_user = "ssm-user"

  create_audit_disk_alarm = true
  alarm_sns_topic_arns    = var.alarm_sns_topic_arns

  tags = local.tags
}

# ---------------------------------------------------------------------
# Two separate node pools, so teams that must not share a host do not.
#
# The access tag value is what IAM matches on, so a distinct value per
# pool is what actually separates them -- not the module instance name.
# ---------------------------------------------------------------------
module "access_node_shared" {
  source = "../../modules/access-node"

  name   = "${var.name}-shared"
  vpc_id = var.vpc_id

  ami_id        = data.aws_ssm_parameter.access_node_ami.value
  instance_type = var.instance_type
  subnet_ids    = var.private_subnet_ids

  min_size         = 1
  max_size         = 4
  desired_capacity = 2

  egress_cidr_blocks = [data.aws_vpc.this.cidr_block]

  access_tag_value = "shared"

  session_log_group_name    = module.session_logging.cloudwatch_log_group_name
  session_log_bucket_arn    = module.session_logging.s3_bucket_arn
  session_log_bucket_prefix = module.session_logging.s3_key_prefix
  session_kms_key_arn       = module.session_logging.kms_key_arn

  tags = merge(local.tags, { NodePool = "shared" })
}

# Payments is in scope for a cardholder-data audit, so it gets its own
# nodes rather than sharing with analytics.
module "access_node_payments" {
  source = "../../modules/access-node"

  name   = "${var.name}-payments"
  vpc_id = var.vpc_id

  ami_id        = data.aws_ssm_parameter.access_node_ami.value
  instance_type = var.instance_type
  subnet_ids    = var.private_subnet_ids

  min_size         = 1
  max_size         = 2
  desired_capacity = 1

  egress_cidr_blocks = [data.aws_vpc.this.cidr_block]

  access_tag_value = "payments"

  session_log_group_name    = module.session_logging.cloudwatch_log_group_name
  session_log_bucket_arn    = module.session_logging.s3_bucket_arn
  session_log_bucket_prefix = module.session_logging.s3_key_prefix
  session_kms_key_arn       = module.session_logging.kms_key_arn

  tags = merge(local.tags, { NodePool = "payments", AuditScope = "cardholder-data" })
}

# ---------------------------------------------------------------------
# Team roles and allowlists
# ---------------------------------------------------------------------
module "access_iam" {
  source = "../../modules/access-iam"

  name = var.name

  access_tag_key        = module.access_node_shared.access_tag_key
  session_document_name = module.session_logging.session_preferences_document_name
  session_kms_key_arn   = module.session_logging.kms_key_arn

  teams = {
    # --- payments: shell on the payments pool, and its own database ---
    payments = {
      access_tag_value       = module.access_node_payments.access_tag_value
      trusted_principal_arns = var.payments_principal_arns

      allow_shell = true

      # One Port document per target, with host and port baked in. The
      # payments team cannot reach the analytics warehouse: its role
      # lists only the document below, and the explicit Deny on
      # AWS-StartPortForwarding* stops it naming a generic document
      # instead.
      forward_targets = {
        db = {
          host        = var.payments_db_host
          port        = 5432
          description = "Payments Aurora PostgreSQL writer endpoint"
        }
      }

      require_mfa         = true
      max_mfa_age_seconds = 3600
    }

    # --- analytics: forwarding only, no shell ------------------------
    analytics = {
      access_tag_value       = module.access_node_shared.access_tag_value
      trusted_principal_arns = var.analytics_principal_arns

      # No shell. This team queries datastores from their own machines;
      # they have no reason to run commands on the access node, and
      # removing it removes a whole class of incident.
      allow_shell = false

      forward_targets = {
        warehouse = {
          host        = var.analytics_db_host
          port        = 5432
          description = "Analytics Redshift/Aurora read replica"
        }
        cache = {
          host        = var.analytics_cache_host
          port        = 6379
          description = "Analytics ElastiCache Redis primary endpoint"
        }
      }

      require_mfa = true
    }

    # --- platform: shell everywhere, and the elevation path ----------
    platform = {
      access_tag_value       = module.access_node_shared.access_tag_value
      trusted_principal_arns = var.platform_principal_arns

      allow_shell = true

      # Local forwarding to the node itself, for debugging an agent or
      # a local diagnostic endpoint.
      local_forward_ports = [8080]

      # THE ELEVATION PATH.
      #
      # Sessions started by this role run as ec2-user, which retains
      # cloud-init's passwordless sudo, rather than the unprivileged
      # ssm-user everyone else gets. Session Manager reads
      # SSMSessionRunAs from the IAM entity's tags and prefers it over
      # the account-wide runAsDefaultUser.
      #
      # This is deliberately a SEPARATE ROLE rather than a sudo rule on
      # the node: assuming it is a distinct, MFA-gated CloudTrail event
      # with its own name, so "who had root on the access node, and
      # when" is answerable from the audit trail rather than from a
      # sudoers file.
      session_run_as_user = "ec2-user"

      require_mfa         = true
      max_mfa_age_seconds = 900 # 15 minutes for the privileged path

      max_session_duration = 3600
    }
  }

  tags = local.tags
}
