# access-iam

Per-team IAM roles and policies for Session Manager access, scoped by
instance tag and by session document.

## The thing to understand first

**IAM cannot restrict port-forwarding targets directly.** There is no
condition key for the `host`, `portNumber`, or `localPortNumber`
parameters of `ssm:StartSession`.

So a team granted `AWS-StartPortForwardingSessionToRemoteHost` can
forward to **anything the access node can reach** — which, for a node
in a private subnet, is most of the VPC, including other teams'
databases. This is the most commonly missed detail in Session Manager
designs, and policies that look tightly scoped routinely have this hole
in them.

What IAM *can* authorize is a **document**. So this module bakes the
target into the document:

```
forward_targets = {
  db = { host = "payments.cluster-abc.rds.amazonaws.com", port = 5432 }
}
```

becomes an SSM document `bfa-pf-payments-db` of type `Port`, with:

```json
{
  "sessionType": "Port",
  "parameters": { "localPortNumber": { "type": "String", "default": "5432" } },
  "properties": {
    "type": "LocalPortForwarding",
    "host": "payments.cluster-abc.rds.amazonaws.com",
    "portNumber": "5432",
    "localPortNumber": "{{ localPortNumber }}"
  }
}
```

`host` and `portNumber` are **properties, not parameters** — the caller
cannot override them. The team's policy lists only its own document
ARNs, and three things make that bite:

1. **`ssm:SessionDocumentAccessCheck`** forces the caller to name a
   document and forces IAM to evaluate access to it. Without this
   condition, granting the shell document can effectively permit other
   documents the caller can reach.
2. **An explicit `Deny` on `AWS-StartPortForwarding*`**, so a team
   cannot escape its allowlist by naming a generic document — even if a
   broader `Allow` appears elsewhere in the account.
3. **An explicit `Deny` on `AWS-StartSSHSession`**, which would bypass
   session logging and reintroduce key management.

### The limits of this approach

- **One document per host/port pair.** Fine for a handful of datastores
  per team; it does not scale to hundreds, and it is infrastructure you
  apply rather than an ACL you edit at run time.
- **`allow_unrestricted_forwarding = true` voids everything above.**
  The module detects a configuration that does both and reports it in
  `terraform output warnings`.
- **`localPortNumber` stays the caller's choice**, which is purely
  local to their machine and is not a security boundary.
- The access node's **egress** security group is the other boundary on
  where a tunnel can reach. Narrow `egress_cidr_blocks` in
  `access-node`.

## Usage

```hcl
module "access_iam" {
  source = "./terraform/modules/access-iam"

  name = "bfa"

  # Pass access-node's outputs so the tag cannot drift.
  access_tag_key        = module.access_node.access_tag_key
  session_document_name = module.session_logging.session_preferences_document_name
  session_kms_key_arn   = module.session_logging.kms_key_arn

  teams = {
    payments = {
      access_tag_value       = module.access_node_payments.access_tag_value
      trusted_principal_arns = ["arn:aws:iam::111122223333:role/AWSReservedSSO_Payments_abc"]
      allow_shell            = true

      forward_targets = {
        db = {
          host        = "payments.cluster-abc.us-east-1.rds.amazonaws.com"
          port        = 5432
          description = "Payments Aurora writer"
        }
      }

      require_mfa         = true
      max_mfa_age_seconds = 3600
    }

    analytics = {
      access_tag_value       = module.access_node_shared.access_tag_value
      trusted_principal_arns = ["arn:aws:iam::111122223333:role/AWSReservedSSO_Analytics_def"]

      # No shell: this team queries datastores from their own machines
      # and has no reason to run commands on the node.
      allow_shell = false

      forward_targets = {
        warehouse = { host = "analytics-ro.cluster-ro-def.rds.amazonaws.com", port = 5432 }
        cache     = { host = "analytics.xyz.ng.0001.use1.cache.amazonaws.com", port = 6379 }
      }
    }
  }
}
```

## Own sessions only

```
ssm:TerminateSession, ssm:ResumeSession  on arn:aws:ssm:*:*:session/${aws:userid}-*
ssmmessages:OpenDataChannel              on arn:aws:ssm:*:*:session/${aws:userid}-*
```

Plus an explicit `Deny` on terminating a session whose
`aws:ssmmessages:session-id` tag does not match the caller.

`${aws:userid}` rather than `${aws:username}`: AWS documents the latter
as **not working for federated identities**, which is most real
deployments.

### What cannot be scoped

`ssm:DescribeSessions` cannot be limited to a caller's own sessions —
it is a list operation with no owner condition key. Callers can see
other users' session IDs and target instances. They cannot join or end
them. Set `allow_describe_sessions = false` if even the listing is too
much; the Session Manager console then stops working.

## MFA and IAM Identity Center

**MFA** is a trust-policy condition (`aws:MultiFactorAuthPresent`, plus
an optional `aws:MultiFactorAuthAge`). It is effective for IAM users and
role chaining, and a **no-op for principals that arrive already
federated** — there, MFA is the identity provider's responsibility. Said
plainly because "we require MFA" is a claim people rely on.

**IAM Identity Center**: set `create_roles = false`. The module then
emits policies only, for attaching to a permission set. Identity Center
manages its own `AWSReservedSSO_*` roles, and a module that tried to
create them would fight the service.

## The elevation path

Set `session_run_as_user` on a team to tag its role with
`SSMSessionRunAs`. Session Manager prefers that tag over the
account-wide `runAsDefaultUser`, so sessions started by that role run as
the named OS user — `ec2-user` retains cloud-init's passwordless sudo,
while every other team lands on `ssm-user`, which the AMI strips of
sudo.

This is deliberately a separate role rather than a sudoers rule:
assuming it is a distinct, MFA-gated `sts:AssumeRole` event in
CloudTrail, so "who had root on the access node, and when" is answerable
from the audit trail. `root` is rejected — Session Manager does not
support authenticating as root.

Requires `run_as_enabled = true` in `session-logging`.

## Explicit denies

Beyond the forwarding denies above, every team policy denies
`ssm:CreateDocument`, `UpdateDocument`, `DeleteDocument`,
`ModifyDocumentPermission`, `SendCommand`, `StartAutomationExecution`,
`UpdateServiceSetting`, and `ResetServiceSetting`.

Those are the escape hatches: document creation would let a caller
define a document running arbitrary commands as root, Run Command is
root on the node and is not session-logged, and the service settings
would let them turn off logging for everyone. An explicit `Deny` cannot
be overridden by any later `Allow`.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | `"bfa"` | Prefix for roles, policies, and documents. |
| `teams` | map(object) | — | Per-team definitions; see below. |
| `create_roles` | bool | `true` | False emits policies only, for Identity Center. |
| `access_tag_key` | string | `"BastionFreeAccess"` | Must equal `access-node`'s. |
| `session_document_name` | string | `"SSM-SessionManagerRunShell"` | Shell document teams may use. |
| `session_kms_key_arn` | string | `""` | Grants `kms:GenerateDataKey`. Empty breaks KMS-encrypted sessions. |
| `allow_describe_sessions` | bool | `true` | Cannot be scoped to own sessions. |
| `enforce_session_document_access_check` | bool | `true` | **Keep true.** |
| `tags` | map(string) | `{}` | |

### The `teams` object

| Field | Type | Default | Description |
|---|---|---|---|
| `access_tag_value` | string | — | Which node pool this team reaches. |
| `trusted_principal_arns` | list(string) | `[]` | Who may assume the role. Required when `create_roles`. |
| `allow_shell` | bool | `true` | Shell access, fully logged. |
| `forward_targets` | map(object) | `{}` | `{ host, port, description }` per allowed target. |
| `local_forward_ports` | list(number) | `[]` | Ports on the node itself. |
| `allow_unrestricted_forwarding` | bool | `false` | **Voids `forward_targets`.** |
| `require_mfa` | bool | `true` | Trust-policy MFA condition. |
| `max_mfa_age_seconds` | number | `null` | 60–43200, or null. |
| `max_session_duration` | number | `3600` | 3600–43200. |
| `session_run_as_user` | string | `""` | The elevation path. Cannot be `root`. |

## Outputs

| Name | Description |
|---|---|
| `role_arns` / `role_names` | Per team. Empty when `create_roles = false`. |
| `policy_arns` | Per team. Attach to Identity Center permission sets. |
| `forward_target_documents` | Document name, host, and port per target. |
| `local_forward_documents` | Local forwarding documents. |
| `team_document_arns` | **The authoritative answer to "what can this team reach".** |
| `connect_commands` | Ready-to-run command per target. |
| `unrestricted_forwarding_teams` | Teams that can forward anywhere. |
| `warnings` | Configuration contradictions. Should be empty. |
| `iam_limitations` | What IAM can and cannot enforce, as data. |

## Check the warnings

```sh
terraform output warnings                        # expect []
terraform output unrestricted_forwarding_teams   # expect []
terraform output team_document_arns              # review this
```

An empty `warnings` list and a reviewed `team_document_arns` is what
"the allowlist is real" looks like.
