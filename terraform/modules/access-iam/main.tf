data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  tags = merge(
    {
      Project   = "bastion-free-ami"
      Module    = "access-iam"
      ManagedBy = "terraform"
    },
    var.tags
  )

  # Flatten teams x forward_targets into one map keyed "<team>:<target>",
  # so each pair becomes its own SSM document and its own policy
  # resource ARN.
  forward_targets = merge([
    for team_name, team in var.teams : {
      for target_name, target in team.forward_targets :
      "${team_name}:${target_name}" => {
        team          = team_name
        target        = target_name
        host          = target.host
        port          = target.port
        description   = target.description
        document_name = "${var.name}-pf-${team_name}-${target_name}"
      }
    }
  ]...)

  local_forward_ports = merge([
    for team_name, team in var.teams : {
      for port in team.local_forward_ports :
      "${team_name}:${port}" => {
        team          = team_name
        port          = port
        document_name = "${var.name}-lpf-${team_name}-${port}"
      }
    }
  ]...)

  # Document ARNs each team may use, assembled per team so the policy
  # can list them as StartSession resources.
  team_document_arns = {
    for team_name, team in var.teams : team_name => concat(
      # Shell access.
      team.allow_shell ? [
        "arn:${local.partition}:ssm:${local.region}:${local.account_id}:document/${var.session_document_name}"
      ] : [],

      # This team's per-target forwarding documents.
      [
        for k, v in local.forward_targets :
        "arn:${local.partition}:ssm:${local.region}:${local.account_id}:document/${v.document_name}"
        if v.team == team_name
      ],

      # This team's local forwarding documents.
      [
        for k, v in local.local_forward_ports :
        "arn:${local.partition}:ssm:${local.region}:${local.account_id}:document/${v.document_name}"
        if v.team == team_name
      ],

      # The generic remote-host document, which makes the allowlist
      # above meaningless. Off by default.
      team.allow_unrestricted_forwarding ? [
        "arn:${local.partition}:ssm:${local.region}:${local.account_id}:document/AWS-StartPortForwardingSessionToRemoteHost",
        "arn:${local.partition}:ssm:${local.region}:${local.account_id}:document/AWS-StartPortForwardingSession",
      ] : [],
    )
  }

  # Teams whose configuration is internally contradictory: a named
  # allowlist alongside the blanket grant that overrides it. Surfaced as
  # an output warning rather than an error, because it is occasionally
  # a deliberate migration step.
  teams_with_defeated_allowlist = [
    for team_name, team in var.teams : team_name
    if team.allow_unrestricted_forwarding && length(team.forward_targets) > 0
  ]
}

resource "terraform_data" "preconditions" {
  input = var.name

  lifecycle {
    precondition {
      condition = alltrue([
        for team_name, team in var.teams :
        team.allow_shell ||
        length(team.forward_targets) > 0 ||
        length(team.local_forward_ports) > 0 ||
        team.allow_unrestricted_forwarding
      ])
      error_message = "Every team must be granted something: set allow_shell, or define forward_targets, local_forward_ports, or allow_unrestricted_forwarding. A team with none of these gets a role that cannot start any session."
    }

    precondition {
      condition = (
        !var.create_roles ||
        alltrue([for team_name, team in var.teams : length(team.trusted_principal_arns) > 0])
      )
      error_message = "With create_roles = true, every team needs trusted_principal_arns, otherwise its role has an empty trust policy and nobody can assume it. For IAM Identity Center, set create_roles = false and attach the emitted policies to a permission set instead."
    }
  }
}
