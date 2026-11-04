# ---------------------------------------------------------------------
# Per-target port forwarding session documents.
#
# THIS IS THE HEART OF THE MODULE, so it is worth being precise about
# why it works this way.
#
# The requirement is per-team host and port allowlists. IAM cannot do
# that directly: there is NO condition key for the `host`, `portNumber`,
# or `localPortNumber` parameters of ssm:StartSession. A team granted
# AWS-StartPortForwardingSessionToRemoteHost can forward to any host and
# port the access node can reach -- which, on a node in a private
# subnet, is most of the VPC.
#
# What IAM *can* authorize is a document. So the target is baked into
# the document instead of being a parameter:
#
#   * a `Port` type session document carries properties.host and
#     properties.portNumber as FIXED values
#   * the caller cannot override them, because they are not parameters
#   * each team's policy lists only its own document ARNs
#   * ssm:SessionDocumentAccessCheck makes that restriction bite
#
# The result is a real allowlist, enforced by AWS, at the cost of one
# managed document per host/port pair.
#
# LIMITS, stated plainly:
#
#   1. One document per host/port pair. Fine for a handful of datastores
#      per team; it does not scale to hundreds, and it is infrastructure
#      you apply rather than an ACL you edit at run time.
#   2. If you also grant the generic remote-host document
#      (allow_unrestricted_forwarding), every allowlist here becomes
#      decorative. The module defaults it off and warns.
#   3. localPortNumber remains the caller's choice. That is purely local
#      to their machine and is not a security boundary.
# ---------------------------------------------------------------------
resource "aws_ssm_document" "forward_target" {
  for_each = local.forward_targets

  name            = each.value.document_name
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description = (
      each.value.description != ""
      ? each.value.description
      : "bastion-free-ami: port forwarding to ${each.value.host}:${each.value.port} for team ${each.value.team}"
    )
    sessionType = "Port"
    parameters = {
      # localPortNumber is the only caller-supplied value. It names a
      # port on the caller's own machine, so it is not a boundary worth
      # defending; host and portNumber are deliberately NOT parameters.
      localPortNumber = {
        type           = "String"
        description    = "Port on your local machine to listen on."
        allowedPattern = "^([0-9]|[1-9][0-9]{1,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$"
        default        = tostring(each.value.port)
      }
    }
    properties = {
      # "LocalPortForwarding" is the port plugin's mode for both local
      # and remote forwarding; the presence of `host` is what makes it
      # remote. This mirrors the AWS-managed
      # AWS-StartPortForwardingSessionToRemoteHost document. Omitting it
      # leaves the agent unable to recognise the session as port
      # forwarding at all.
      type            = "LocalPortForwarding"
      host            = each.value.host
      portNumber      = tostring(each.value.port)
      localPortNumber = "{{ localPortNumber }}"
    }
  })

  tags = merge(
    local.tags,
    {
      Name           = each.value.document_name
      Team           = each.value.team
      ForwardHost    = each.value.host
      ForwardPort    = tostring(each.value.port)
      BastionFreeUse = "port-forward-allowlist"
    }
  )
}

# ---------------------------------------------------------------------
# Local port forwarding documents: a port on the access node itself,
# rather than a remote host. Same reasoning -- portNumber is a fixed
# property, not a parameter.
# ---------------------------------------------------------------------
resource "aws_ssm_document" "local_forward" {
  for_each = local.local_forward_ports

  name            = each.value.document_name
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "bastion-free-ami: port forwarding to port ${each.value.port} on the access node, for team ${each.value.team}"
    sessionType   = "Port"
    parameters = {
      localPortNumber = {
        type           = "String"
        description    = "Port on your local machine to listen on."
        allowedPattern = "^([0-9]|[1-9][0-9]{1,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$"
        default        = tostring(each.value.port)
      }
    }
    properties = {
      type            = "LocalPortForwarding"
      portNumber      = tostring(each.value.port)
      localPortNumber = "{{ localPortNumber }}"
    }
  })

  tags = merge(
    local.tags,
    {
      Name           = each.value.document_name
      Team           = each.value.team
      ForwardPort    = tostring(each.value.port)
      BastionFreeUse = "local-port-forward-allowlist"
    }
  )
}
