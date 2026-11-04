# Audit evidence

What this kit produces that helps with a SOC 2 or ISO 27001 review,
where the gaps are, and how to describe both honestly.

> **This is supporting evidence, not compliance.** Deploying this kit
> does not make an account compliant, certified, or attested. It
> produces artefacts that help you *demonstrate* controls you operate.
> No open-source template can be compliant on your behalf, and anyone
> who tells you otherwise is selling something. Your auditor assesses
> your control environment; this gives you something to show them.

## The one sentence to get right

Teams get into trouble with auditors by saying **"all access is
logged."** An auditor hears that as "you can show me what was done."
For port-forwarding sessions, you cannot.

Say this instead:

> All access is **recorded**: every session's principal, target, chosen
> session document, start and end time, duration, and source IP are
> captured in CloudTrail. Session **content** is captured for
> interactive shell sessions only. Port-forwarding sessions are
> recorded as having occurred, but their traffic is not captured —
> AWS does not offer this. Statement-level visibility for database
> access is provided separately by the database engine's own audit log.

That is accurate, it is defensible, and it does not collapse the first
time an auditor asks a follow-up question.

## Evidence this kit produces

### Identification and authentication

| Evidence | Where | Demonstrates |
|---|---|---|
| Every session tied to a named IAM principal | CloudTrail `StartSession`, `userIdentity` | No shared or anonymous access |
| MFA condition on role assumption | Team role trust policies (`module.access_iam`) | MFA enforced for privileged access |
| No SSH keys anywhere | `scripts/verify`, Goss `goss_no_ssh.yaml` | No unmanaged standing credentials |
| No static AWS credentials on hosts | Instance role only; Goss and Trivy secret scan | No long-lived keys to rotate or leak |
| Role session duration limits | `max_session_duration` per team | Bounded credential lifetime |

### Authorisation and least privilege

| Evidence | Where | Demonstrates |
|---|---|---|
| Per-team roles, no shared access role | `module.access_iam.role_arns` | Segregation of duties |
| Access scoped by instance tag | `ssm:resourceTag` condition on `StartSession` | Teams reach only their own nodes |
| Target allowlists per team | `module.access_iam.team_document_arns` | Approved-destination enforcement |
| `Deny` on generic forwarding documents | Team policies | Allowlist cannot be bypassed |
| Users can only end their own sessions | `session/${aws:userid}-*` scoping | No interference between users |
| Sessions are unprivileged | Goss `goss_access_node.yaml`, smoke test | No default administrative access |
| Elevation is a separate audited role | `SSMSessionRunAs` tagged role | Privileged access is explicit and attributable |
| Instance role is minimal | `module.access_node` IAM policy | Least privilege on the host |

### Network controls

| Evidence | Where | Demonstrates |
|---|---|---|
| No public IPs | `scripts/verify`, `terraform test` | No internet-exposed access infrastructure |
| No inbound security group rules | `scripts/verify`, `terraform test` | Deny-by-default ingress |
| Port 22 closed | `scripts/verify` | Legacy access path removed |
| Private subnets only, optionally no NAT | `private-subnets` example | Minimised egress and blast radius |
| Host firewall default-deny | Goss `goss.yaml` | Defence in depth |

### Logging and monitoring

| Evidence | Where | Demonstrates |
|---|---|---|
| Shell session transcripts | CloudWatch Logs group | Activity monitoring for interactive access |
| Session start/end records | CloudTrail | Access logging and attribution |
| Defined retention | Log group retention (0 rejected by the module) | Records retention policy |
| KMS encryption with a CMK | Log group and S3 archive | Protection of audit data at rest |
| Immutable-ish archive | S3 versioning, public access blocked | Audit trail integrity |
| Host-level audit records | `auditd` → CloudWatch Agent | OS-level activity monitoring |
| Disk-pressure alarm | `create_audit_disk_alarm` | Monitoring of the logging pipeline itself |

### Change management and system integrity

| Evidence | Where | Demonstrates |
|---|---|---|
| AMI built from a pipeline, not by hand | `.github/workflows/` | Controlled change process |
| Test and scan gates before publish | Goss suites, Trivy | Pre-deployment security validation |
| No AMI builds on pull requests | Workflow separation | Untrusted code cannot publish an image |
| OIDC, no static CI credentials | `aws-actions/configure-aws-credentials` | Pipeline credential hygiene |
| Pinned dependencies with checksums | `packer/variables.pkr.hcl`, workflow SHAs | Supply chain integrity |
| Weekly rebuild | Scheduled workflow | Patch management |
| Vulnerability scan results retained | Workflow artefacts, 90 days | Vulnerability management evidence |
| Infrastructure as code, reviewed | This repository | Change authorisation |

## Mapping to framework criteria

Indicative only — your auditor decides what satisfies what, and scoping
differs by organisation.

### SOC 2 (Trust Services Criteria)

| Criterion | Relevant evidence |
|---|---|
| CC6.1 — logical access controls | Per-team IAM roles, tag scoping, document allowlists, no SSH keys |
| CC6.2 — registration and authorisation | IAM principal lifecycle; access is a policy attachment, not a key handout |
| CC6.3 — role-based access | `module.access_iam` teams, per-team allowlists |
| CC6.6 — boundary protection | No public IPs, no inbound rules, private subnets, optional no-NAT |
| CC6.7 — restricting data movement | Egress-only groups; note the tunnel-content gap below |
| CC6.8 — malicious software prevention | Trivy gate, minimal image, no package installs at runtime |
| CC7.1 — detecting configuration changes | `scripts/verify`, Goss suites, `terraform plan` drift |
| CC7.2 — monitoring for anomalies | Session queries in `docs/queries/`, disk alarm |
| CC7.3 / CC7.4 — incident response | Lockout runbook and rollback path in `docs/migrating-from-a-bastion.md` |
| CC8.1 — change management | Pipeline gates, IaC, no PR builds, pinned dependencies |

### ISO/IEC 27001:2022 (Annex A)

| Control | Relevant evidence |
|---|---|
| A.5.15 — access control | Per-team roles and allowlists |
| A.5.16 — identity management | IAM principals; no node-local accounts to manage |
| A.5.17 — authentication information | No SSH keys or static credentials; MFA conditions |
| A.5.18 — access rights | Tag and document scoping; revocation by policy detachment |
| A.8.2 — privileged access rights | Separate `SSMSessionRunAs` role, MFA-gated, audited |
| A.8.3 — information access restriction | Per-target session documents |
| A.8.5 — secure authentication | IAM + MFA; IAM database authentication where it fits |
| A.8.9 — configuration management | Packer, Ansible, Terraform, Goss |
| A.8.15 — logging | Session logs, CloudTrail, `auditd` |
| A.8.16 — monitoring activities | Logs Insights queries, alarms |
| A.8.20 — network security | No ingress, private subnets, endpoints |
| A.8.21 — security of network services | VPC endpoints, TLS throughout |
| A.8.22 — segregation of networks | Separate node pools per team (`multi-team`) |
| A.8.28 — secure coding | Linting, scanning, IaC review in CI |
| A.8.31 — separation of environments | Separate deployments per environment; tag-scoped access |

## The gaps, and what to do about them

Bring these up before your auditor finds them. A gap you have named,
assessed, and compensated for reads as a mature control environment; the
same gap discovered during fieldwork reads as a surprise.

| Gap | Impact | Compensating control |
|---|---|---|
| **Port-forwarding traffic not captured** | You cannot evidence *what* was done over a tunnel | Enable the datastore's own audit logging (RDS `pgaudit` / MariaDB audit plugin, EKS audit logs, ALB access logs) and correlate by time and source IP |
| Credentials may appear in shell transcripts | Session logs become secret-bearing | KMS CMK, scoped log group access, banner, `stty -echo` guidance |
| `ssm:DescribeSessions` cannot be scoped to own sessions | Users can see others' session IDs and targets | Cannot join or end them; set `allow_describe_sessions = false` if unacceptable |
| `openssh-server` present though masked | A root-level attacker could unmask it | No inbound rules; deny-all `sshd_config` drop-in; reported in the advisory Goss suite |
| `admin_space_left_action` is not `halt` | Audit records can rotate away under flood | Off-box logging, continuous streaming, disk alarm — see the threat model |
| Session preferences are account-wide | Another team can change your logging config | Use `custom_preferences_document_name` |
| Local `auditd` is not tamper-proof against node root | OS audit trail is not authoritative | CloudTrail and session logs are off-box and are the authoritative record |

## Producing evidence for a review

```sh
# 1. Posture snapshot. Read-only, safe to run in production.
scripts/verify --tag BastionFreeAccess=shared \
               --log-group /aws/ssm/bfa/sessions \
               --s3-bucket bfa-session-logs-111122223333 \
               --json > evidence/posture-$(date +%F).json

# 2. Who connected to what, over the review period.
#    See docs/queries/ for the full set.
aws logs start-query \
  --log-group-name /aws/ssm/bfa/sessions \
  --start-time "$(date -d '90 days ago' +%s)" \
  --end-time "$(date +%s)" \
  --query-string "$(cat docs/queries/logs-insights-who-connected.txt)"

# 3. The authoritative session record, from CloudTrail.
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=StartSession \
  --start-time "$(date -d '90 days ago' -Iseconds)" \
  --output json > evidence/sessions-$(date +%F).json

# 4. The build-time control evidence for the running AMI.
#    Goss and Trivy reports are workflow artefacts, retained 90 days.
gh run download --name bastion-free-ami-reports --dir evidence/ami-reports/

# 5. The effective access grants, per team.
cd terraform/examples/multi-team && terraform output -json team_document_arns \
  > ../../../evidence/access-grants-$(date +%F).json
```

Keep these outside the 90-day artefact window if your retention
requirement is longer — the pipeline does not archive them for you.

## What to tell an auditor about this repository

- It is an open-source kit from Jet1, deployed and operated by you.
- Its security claims are tested in CI: Goss suites gate the AMI,
  `terraform test` asserts the infrastructure invariants, and a test
  enforces that the audit script makes no write calls.
- Its limitations are documented in `docs/threat-model.md` rather than
  discovered during fieldwork.
- It is not certified against anything, and it does not claim to be.
