output "role_arns" {
  description = "Map of team name to IAM role ARN. Empty when create_roles is false."
  value       = { for k, v in aws_iam_role.team : k => v.arn }
}

output "role_names" {
  description = "Map of team name to IAM role name. Empty when create_roles is false."
  value       = { for k, v in aws_iam_role.team : k => v.name }
}

output "policy_arns" {
  description = "Map of team name to IAM policy ARN. Attach these to IAM Identity Center permission sets when create_roles is false."
  value       = { for k, v in aws_iam_policy.team : k => v.arn }
}

output "forward_target_documents" {
  description = "Map of \"<team>:<target>\" to the SSM document name that forwards to that host and port. These are the per-team allowlist: the host and port are fixed properties of the document, not caller-supplied parameters."
  value = {
    for k, v in local.forward_targets : k => {
      document_name = v.document_name
      host          = v.host
      port          = v.port
      team          = v.team
    }
  }
}

output "local_forward_documents" {
  description = "Map of \"<team>:<port>\" to the SSM document name forwarding to that port on the access node itself."
  value = {
    for k, v in local.local_forward_ports : k => {
      document_name = v.document_name
      port          = v.port
      team          = v.team
    }
  }
}

output "team_document_arns" {
  description = "Map of team name to the session document ARNs that team may use. This is the authoritative answer to \"what can this team actually connect to\"."
  value       = local.team_document_arns
}

#
# Honesty outputs. These exist so the module's limits are reported by the
# module itself, rather than living only in a document somebody may not
# read.
#
output "connect_commands" {
  description = "Ready-to-run connect command per forwarding target, with the right document and port for this deployment."
  value = {
    for k, v in local.forward_targets : k => join(" ", [
      "aws ssm start-session",
      "--region ${local.region}",
      "--target <instance-id>",
      "--document-name ${v.document_name}",
      "--parameters '{\"localPortNumber\":[\"${v.port}\"]}'",
    ])
  }
}

output "unrestricted_forwarding_teams" {
  description = "Teams granted the generic remote-host forwarding document. These teams can forward to ANY host and port their access node can reach, regardless of any forward_targets allowlist, because IAM has no condition key for port-forwarding parameters."
  value = [
    for team_name, team in var.teams : team_name
    if team.allow_unrestricted_forwarding
  ]
}

output "warnings" {
  description = "Configuration contradictions worth seeing at apply time. Empty list means none."
  value = concat(
    [
      for team_name in local.teams_with_defeated_allowlist :
      "Team '${team_name}' defines forward_targets AND allow_unrestricted_forwarding = true. The allowlist has no effect: the generic document lets this team forward anywhere the access node can reach. Remove allow_unrestricted_forwarding to make the allowlist real."
    ],
    var.enforce_session_document_access_check ? [] : [
      "enforce_session_document_access_check = false. Without the ssm:SessionDocumentAccessCheck condition, granting a team the shell document can effectively permit other session documents it can reach, which defeats the per-team forwarding allowlists."
    ],
    var.session_kms_key_arn == "" ? [
      "session_kms_key_arn is empty, so teams have no kms:GenerateDataKey grant. If session-logging enabled KMS encryption of session data, sessions will fail to start."
    ] : [],
  )
}

output "iam_limitations" {
  description = "What IAM can and cannot enforce here, returned as data so a runbook or audit response can quote it accurately instead of restating it from memory."
  value = {
    port_forward_parameters_not_conditionable = "IAM has no condition key for the host, portNumber, or localPortNumber parameters of ssm:StartSession. Per-target allowlists are therefore enforced by minting one Port session document per host/port pair with the target as a fixed property, and granting each team only its own documents."
    describe_sessions_not_scopable            = "ssm:DescribeSessions cannot be limited to a caller's own sessions; it is a list operation with no owner condition key. Callers can see other users' session IDs and targets, but cannot join or end them."
    mfa_scope                                 = "The MFA condition applies to sts:AssumeRole on these roles. It is effective for IAM users and role chaining, and a no-op for principals arriving already federated, where MFA is the identity provider's responsibility."
    identity_center                           = "With create_roles = false this module emits policies only. IAM Identity Center manages its own AWSReservedSSO_* roles; attach policy_arns to a permission set. Session ARNs are scoped with aws:userid rather than aws:username because AWS documents aws:username as not working for federated identities."
    terminate_own_sessions                    = "Scoped with arn:aws:ssm:*:*:session/$${aws:userid}-*, plus an explicit Deny on ending sessions whose aws:ssmmessages:session-id tag does not match the caller."
  }
}
