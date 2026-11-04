# Threat model

What this kit defends against, what it does not, and the trade-offs it
makes on purpose. Read the last two sections even if you skip the rest.

## Scope

**In scope:** the path a human takes to reach a private AWS resource —
the access node's OS, its IAM boundary, the network exposure of the
access path, and the audit record of who used it.

**Out of scope:** your application's security, the datastores
themselves, your VPC and security group design beyond the access node,
IAM outside this kit's roles, upstream Amazon Linux package supply
chain, and compliance certification of any kind.

## What the design removes

| Threat | How it is addressed |
|---|---|
| Internet-reachable bastion scanned and brute-forced | No public IP, no inbound rule, nothing listening. There is no address to scan. |
| Stolen or stale SSH key grants access indefinitely | No SSH keys exist. Access is an IAM decision evaluated per session, revocable immediately by detaching a policy. |
| Departed employee retains access via a key in a password manager | Removing their IAM principal removes access. There is no second credential to hunt down. |
| Shared bastion account with no attribution | Every session is attributed to an IAM principal in CloudTrail. |
| Static AWS credentials on the bastion | The node uses an instance role. No long-lived key exists on it. |
| Credential theft via IMDSv1 SSRF | IMDSv2 required, hop limit 1. A proxied or containerised process cannot reach the metadata service. |
| Privilege escalation after landing a session | Sessions run as `ssm-user` with its sudo grant removed at bake time. Elevation is a separate, MFA-gated, separately audited IAM role. |
| Lateral movement from the access node | Egress-only security group, narrowable to the VPC CIDR. The `private-subnets` example has no internet route at all. |
| Snapshot or volume exfiltration | Root volume and snapshots encrypted unconditionally. |
| Bastion drifting into a pet with secrets on it | Nodes are ASG-managed and replaced; the image ships no tooling and keeps no state. Anything left in a home directory is gone on replacement. |
| Hostile AMI injected into the pipeline | Blocking Goss suites and a Trivy gate before publish, OIDC with no static keys, and no AMI builds on pull requests. |
| Compromised test/scan binary | Goss and Trivy pinned by version and verified against the publisher's checksum before execution. |

## The limits, stated plainly

### 1. Port-forwarding traffic contents are not logged

The single most important limitation, and the one most often assumed
away. AWS:

> Logging isn't available for Session Manager sessions that connect
> through port forwarding or SSH. This is because SSH encrypts all
> session data within the secure TLS connection established between the
> AWS CLI and Session Manager endpoints, and Session Manager only serves
> as a tunnel for SSH connections.

So for every path except an interactive shell — which means RDS,
ElastiCache, internal HTTP, and the EKS API — you get:

- **what you do have:** principal, target instance, session document,
  start time, end time, duration, source IP, and the `--reason` string,
  in CloudTrail and the Session Manager session history.
- **what you do not have:** the SQL, the HTTP requests, the keys read,
  the rows returned. Anything about what passed through the tunnel.

**Consequences you should plan for:**

- You cannot answer "what did they query?" from this kit alone. If a
  control requires that, it must come from the datastore's own audit
  log — `docs/access-paths.md` names the setting for each one.
- A detection rule written against session logs will not fire on
  anything done through a tunnel.
- An auditor told "all access is logged" will reasonably infer content
  logging. Say "all access is *recorded*; session content is captured
  for shell sessions only" instead. `docs/audit-evidence.md` phrases
  this for you.

### 2. Shell session logs capture credentials

The converse problem. Shell sessions log keystrokes, so a password
typed at a prompt is written to CloudWatch Logs and to the S3 archive,
where it is readable by everyone with access to those — a wider group
than the people who knew the password.

Mitigations: the AMI's session banner warns about it on every login,
the log group and bucket are KMS-encrypted with a customer-managed key,
and `stty -echo; read VAR; stty echo` is documented. None of these stop
a determined mistake. Treat the session log group as a secret-bearing
store and scope access to it accordingly.

### 3. A privileged instance role is a privileged session

Anything the access node's instance role can do, anyone with a shell on
that node can do. This is why `terraform/modules/access-node` grants
only the five Session Manager actions AWS documents as the minimum plus
scoped log writes, and deliberately does **not** attach
`AmazonSSMManagedInstanceCore` — that managed policy adds Run Command
document access, Parameter Store reads, and broad S3 access.

If you add `additional_policy_arns`, you are granting it to every
person who can open a session. The variable's description says so.

### 4. IAM cannot restrict port-forwarding targets directly

There is no condition key for the `host` or `portNumber` parameters of
`ssm:StartSession`. A team granted
`AWS-StartPortForwardingSessionToRemoteHost` can forward to **anything
the access node can reach**, which in a private subnet is most of the
VPC — including datastores belonging to other teams.

This kit works around it by minting one `Port` session document per
allowed target, with the host and port as fixed properties, and
granting each team only its own documents plus an explicit `Deny` on
`AWS-StartPortForwarding*`. That is a real allowlist. But it only holds
if you do not also grant the generic document;
`module.access_iam.warnings` tells you when a configuration has
defeated itself.

Residual risk: the access node's security group egress is the only
other boundary on where a tunnel can reach. Narrow
`egress_cidr_blocks` to the VPC CIDR, or tighter.

### 5. `sshd` is masked, not removed

`openssh-server` is still installed, because Packer provisions the
image over SSH and uninstalling it mid-build severs the connection that
the Goss and Trivy gates depend on.

Residual risk: an attacker with root on the node could `systemctl
unmask sshd && systemctl start sshd`. They would then face a security
group with no inbound rules, and the `sshd_config` drop-in this role
installs denies root, passwords, forwarding, and every user by name. An
attacker who already has root on the node has better options than
restarting sshd, so this is a small gap — but it is a gap, and
`goss_advisory.yaml` reports the package as present rather than hiding
it.

### 6. `admin_space_left_action` is not `halt`

The upstream `hardened-al2023` baseline halts an instance when its
audit partition fills, per CIS: a host that cannot guarantee its audit
trail should stop rather than silently lose events. **This project
overrides that**, and the override is an availability-over-audit trade.

Why, on this host specifically: the access node *is* the access path.
A full audit partition during an incident — exactly when session and
audit volume spike — would halt the node and remove every engineer's
route into the VPC at the moment they most need it. The failure mode is
self-reinforcing. Worse, anyone holding a session can generate audit
events, which turns `halt` into a denial-of-service primitive against
the whole team's access.

What makes the trade acceptable:

1. The authoritative record of who connected to what lives **off this
   host**, in CloudTrail and CloudWatch Logs, unaffected by its local
   disk. Local `auditd` output is corroborating detail.
2. Logs ship continuously, so the window of locally-held-only data is
   small.
3. The ASG replaces an unhealthy node; a halted one just sits there.
4. `session-logging` can raise a CloudWatch alarm on disk pressure —
   an alarm rather than an outage.

Residual risk: a sustained flood of audit events can rotate older
records away before they ship. If your posture requires `halt`, set
`access_node_auditd_admin_space_left_action: halt` and accept that a
full disk removes your access path.

### 7. EICE reintroduces inbound SSH

If you enable `terraform/modules/eice`, the target host needs an
inbound rule on port 22 from the endpoint. Narrower than a public
bastion — the source is an AWS-managed endpoint, not the internet — but
a real inbound path, and `scripts/verify` will report it as one. It is
off by default and requires a second explicit acknowledgement.

### 8. Session preferences are account-wide

`SSM-SessionManagerRunShell` is one document per account per region.
Another team, or another Terraform state, can change your logging
configuration without touching this kit. Using
`custom_preferences_document_name` isolates you from that; it is why
that is the recommended path.

### 9. Scale-to-zero can lock you out

An ASG scheduled to zero out of hours is a cost control and a lockout
risk. It is off by default. When on, the scale-up command is a module
output, needs only `autoscaling:SetDesiredCapacity`, and is in the
runbook — but somebody has to know to run it at 02:00.

### 10. What a compromised AWS control plane means

If an attacker holds IAM credentials with `ssm:StartSession` on a
tagged node, they have the access the node has, and no network control
in this kit will stop them. This architecture moves the security
boundary from the network to IAM — which is the point, and also the
concentration of risk. Guard it accordingly: MFA on the team roles,
short role session durations, CloudTrail alerting on unusual session
starts (`docs/queries/` has the queries), and SCPs preventing session
starts from outside expected conditions.

## Residual risks, summarised

| Risk | Severity | Mitigation | Accepted because |
|---|---|---|---|
| Tunnel contents unlogged | High for audit scope | Datastore-level audit logging | AWS does not offer it; stated explicitly everywhere |
| Credentials in shell logs | Medium | Banner, KMS, `stty -echo` | Cannot be prevented technically |
| `sshd` present though masked | Low | No inbound rules, deny-all drop-in | Build integrity requires SSH during bake |
| Audit records rotated under flood | Medium | Off-box logging, disk alarm | Keeping the access path up matters more |
| Instance role reachable from any session | Medium | Minimal role, no managed SSM policy | Inherent to the model |
| IAM compromise grants access | High | MFA, short sessions, CloudTrail alerting | Inherent to moving the boundary to IAM |

## Reporting

Found something not listed here? See [SECURITY.md](../SECURITY.md).
Please do not open a public issue for a security problem.
