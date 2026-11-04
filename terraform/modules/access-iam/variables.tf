variable "name" {
  type        = string
  description = "Name prefix for roles, policies, and session documents."
  default     = "bfa"

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{0,20}$", var.name))
    error_message = "name must be 1-21 characters of letters, digits, and hyphens (it prefixes IAM role and SSM document names)."
  }
}

variable "teams" {
  type = map(object({
    # Which access nodes this team may reach, matched with the
    # ssm:resourceTag condition on ssm:StartSession.
    access_tag_value = string

    # Principals allowed to assume this team's role. ARNs of IAM users,
    # roles, or an account root. Leave empty when attaching the emitted
    # policy to an IAM Identity Center permission set instead -- see
    # create_roles.
    trusted_principal_arns = optional(list(string), [])

    # Shell access to the access node. Fully logged (keystrokes and
    # output) when session-logging is enabled.
    allow_shell = optional(bool, true)

    # Per-target port-forwarding allowlist. Each entry mints a dedicated
    # Port session document with the host and port baked in as fixed
    # properties, and grants this team only its own documents.
    #
    # This is the ONLY way to allowlist forwarding targets. IAM has no
    # condition key for the host/portNumber parameters of
    # ssm:StartSession, so a team granted the generic
    # AWS-StartPortForwardingSessionToRemoteHost document can forward
    # anywhere the node can reach. See the module README.
    forward_targets = optional(map(object({
      host        = string
      port        = number
      description = optional(string, "")
    })), {})

    # Local port forwarding to a port on the access node itself.
    local_forward_ports = optional(list(number), [])

    # Grant the generic remote-host forwarding document. Doing this
    # makes forward_targets above decorative: the team can reach any
    # host and port the node can. Off by default, and the module warns.
    allow_unrestricted_forwarding = optional(bool, false)

    # Require MFA to assume this team's role. Applies to the trust
    # policy, so it is effective for IAM users and role chaining, and a
    # no-op for principals that arrive already federated.
    require_mfa = optional(bool, true)

    # Maximum age in seconds of the MFA assertion. null omits the check.
    max_mfa_age_seconds = optional(number, null)

    # Session duration for the assumed role itself (not the SSM
    # session). AWS allows 3600-43200.
    max_session_duration = optional(number, 3600)

    # OS user sessions run as, applied by tagging the role with
    # SSMSessionRunAs. Requires run_as_enabled in session-logging.
    # Cannot be root. This is the documented elevation path: a separate,
    # separately auditable role tagged with a privileged OS user.
    session_run_as_user = optional(string, "")
  }))
  description = "Per-team access definitions. One IAM role (or one policy, under Identity Center) per entry."

  validation {
    condition     = length(var.teams) > 0
    error_message = "teams must define at least one team."
  }

  validation {
    condition = alltrue([
      for k, v in var.teams : can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{0,30}$", k))
    ])
    error_message = "Team keys must be 1-31 characters of letters, digits, and hyphens (they appear in IAM role and SSM document names)."
  }

  validation {
    condition = alltrue([
      for k, v in var.teams : alltrue([
        for tk, tv in v.forward_targets : tv.port > 0 && tv.port < 65536
      ])
    ])
    error_message = "Every forward_targets port must be between 1 and 65535."
  }

  validation {
    condition = alltrue([
      for k, v in var.teams : alltrue([
        for p in v.local_forward_ports : p > 0 && p < 65536
      ])
    ])
    error_message = "Every local_forward_ports entry must be between 1 and 65535."
  }

  validation {
    condition = alltrue([
      for k, v in var.teams : alltrue([
        for tk, tv in v.forward_targets : can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,252}$", tv.host))
      ])
    ])
    error_message = "Every forward_targets host must be a hostname or IP address (letters, digits, dots, hyphens, underscores)."
  }

  validation {
    condition = alltrue([
      for k, v in var.teams : alltrue([
        for tk, tv in v.forward_targets : can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{0,40}$", tk))
      ])
    ])
    error_message = "Every forward_targets key must be 1-41 characters of letters, digits, and hyphens (it appears in an SSM document name)."
  }

  validation {
    condition = alltrue([
      for k, v in var.teams : v.session_run_as_user != "root"
    ])
    error_message = "session_run_as_user cannot be root. Session Manager does not support authenticating sessions as root, and sessions on an access node must not be privileged."
  }

  validation {
    condition = alltrue([
      for k, v in var.teams :
      v.max_session_duration >= 3600 && v.max_session_duration <= 43200
    ])
    error_message = "max_session_duration must be between 3600 and 43200 seconds (the range sts:AssumeRole accepts)."
  }

  validation {
    condition = alltrue([
      for k, v in var.teams :
      v.max_mfa_age_seconds == null || (v.max_mfa_age_seconds >= 60 && v.max_mfa_age_seconds <= 43200)
    ])
    error_message = "max_mfa_age_seconds must be between 60 and 43200, or null to omit the check."
  }
}

variable "create_roles" {
  type        = bool
  description = "Create an IAM role per team. Set false to emit only the policies, for attaching to IAM Identity Center permission sets -- Identity Center manages its own AWSReservedSSO_* roles and a module that tried to create them would fight the service."
  default     = true
}

variable "access_tag_key" {
  type        = string
  description = "Tag key matched by the ssm:resourceTag condition. Must equal the access-node module's access_tag_key; pass that module's output straight in so they cannot drift."
  default     = "BastionFreeAccess"

  validation {
    condition     = can(regex("^[a-zA-Z0-9+=._:@/-]{1,128}$", var.access_tag_key))
    error_message = "access_tag_key must be a valid AWS tag key."
  }
}

variable "session_document_name" {
  type        = string
  description = "Session document teams may use for shell access. Use session-logging's session_preferences_document_name output. Defaults to the AWS account-wide document."
  default     = "SSM-SessionManagerRunShell"
}

variable "session_kms_key_arn" {
  type        = string
  description = "ARN of the session KMS key. Teams are granted kms:GenerateDataKey on it, which Session Manager requires when session data is KMS-encrypted. Empty omits the grant, in which case KMS-encrypted sessions will fail to start."
  default     = ""
}

variable "allow_describe_sessions" {
  type        = bool
  description = "Allow teams to list sessions in the account (ssm:DescribeSessions). Cannot be scoped to a principal's own sessions -- it is a list operation with no condition key -- so it reveals other users' session IDs and target instances. Needed for the Session Manager console."
  default     = true
}

variable "enforce_session_document_access_check" {
  type        = bool
  description = "Add the ssm:SessionDocumentAccessCheck condition to ssm:StartSession. Keep this true: without it, a policy granting the shell document can effectively permit other documents the caller can reach, which silently defeats per-team forwarding allowlists."
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource this module creates."
  default     = {}
}
