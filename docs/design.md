# Design

This document records the architecture of `bastion-free-ami` and the
decisions behind it, including how it reuses
[`hardened-al2023`](https://github.com/jetonecloud/hardened-al2023). It is
written to be read before the code, and to be argued with.

## What this project is

A team runs a public bastion host so engineers can reach private RDS
instances, ElastiCache clusters, internal HTTP services, and private EKS
API endpoints. That bastion has a public IP, an inbound rule on port 22,
and a set of SSH keys nobody has rotated since the person who created them
left.

This kit replaces that bastion with an **access node**: an Auto Scaling
Group of private, no-public-IP, no-inbound-rule, no-SSH-key EC2 instances
that engineers reach through AWS Systems Manager Session Manager. Access is
granted by IAM, scoped by instance tag and by which SSM session document a
team may use, and every session start and stop is recorded in CloudTrail
and (for shell sessions) in CloudWatch Logs.

### What "bastion-free" does and does not mean

It means: **no public bastion, no public IP, no inbound security group
rule, no SSH key, and no static AWS credential on the access node.**

It does not mean "no instance". Reaching a private RDS endpoint still
requires something inside the VPC to terminate the TCP connection and
forward it. Session Manager port forwarding needs a managed node to forward
*through*; AWS does not offer a serverless way to tunnel arbitrary TCP into
a private subnet. So this kit still runs an instance — it is just an
instance with no attack surface reachable from the internet and no
credential to steal.

Anyone who tells you otherwise is either selling something or counting a
VPC Lattice / PrivateLink setup (a different architecture, for exposing
specific services, not for interactive access) as the same thing.

## Architecture

```
  Engineer's laptop
       │  aws ssm start-session  (IAM-authenticated, TLS)
       │  + session-manager-plugin
       ▼
  ┌─────────────────────────────────────────────────────────────┐
  │ Systems Manager (regional service endpoint)                 │
  │   · authorizes against IAM: tag + session document          │
  │   · writes session metadata to CloudTrail                   │
  │   · streams shell session I/O to CloudWatch Logs (KMS)      │
  └─────────────────────────────────────────────────────────────┘
       │  SSM Agent holds an *outbound* control channel
       │  (no inbound rule exists on the node)
       ▼
  ┌──────────────── private subnet, no public IP ───────────────┐
  │  access node (ASG, multi-AZ)                                │
  │   · sshd masked + disabled, port 22 not listening           │
  │   · no authorized_keys, no EC2 key pair                     │
  │   · IMDSv2 required, hop limit 1                            │
  │   · instance role: SSM core + logging only                  │
  └─────────────────────────────────────────────────────────────┘
       │  plain TCP, inside the VPC
       ▼
  RDS / Aurora · ElastiCache · internal ALB · private EKS API
```

Nothing in that path requires an inbound security group rule on the access
node. SSM Agent dials out to `ssmmessages` and holds the channel open; the
service pushes work down it. This is the whole reason the design works, and
it is also why `docs/threat-model.md` spends most of its time on the IAM
boundary rather than on the network.

## Repository layout

```
.
├── packer/                  Packer HCL2 build (one template, two arches)
├── ansible/roles/access_node/
│                            Access-node-specific role (the only role this
│                            repo owns; see "Reusing hardened-al2023")
├── tests/
│   ├── goss/                Blocking + advisory compliance suites
│   ├── scripts/             Tests for scripts/ (incl. the read-only proof)
│   └── smoke-test.sh        Boots the AMI, proves port 22 is closed
├── terraform/
│   ├── modules/
│   │   ├── access-node/     Launch template + ASG + optional schedule
│   │   ├── access-iam/      Per-team roles, tag + document scoping
│   │   ├── session-logging/ KMS, CloudWatch Logs, S3 archive, preferences
│   │   ├── vpc-endpoints/   Interface/gateway endpoints for no-NAT subnets
│   │   └── eice/            EC2 Instance Connect Endpoint (off by default)
│   └── examples/            minimal · private-subnets · multi-team
├── scripts/
│   ├── connect              Thin AWS CLI wrapper (shell / port forward)
│   └── verify               Read-only posture check
└── docs/
```

## Decision: how this builds on `hardened-al2023`

This was the main open question. The options were to use the published
`hardened-al2023` AMI as the Packer source, or to vendor its Ansible roles
into this repo.

**Decision: use the published AMI as the source, by default, and make the
alternative a one-variable flip.**

`packer/sources.pkr.hcl` resolves its source AMI through a
`source_ami_filter`, and `ansible/playbook.yml` conditionally includes the
upstream roles:

| Mode | `source_ami_name_filter` | `source_ami_owners` | `apply_upstream_hardening` | Roles that run |
|---|---|---|---|---|
| `hardened-ami` (default) | `hardened-al2023-*` | `["self"]` | `false` | `access_node` |
| `al2023-base` | `al2023-ami-2023.*` | `["amazon"]` | `true` | upstream roles, then `access_node` |

Switch by passing `-var-file=al2023-base.pkrvars.hcl`. In `al2023-base`
mode the upstream roles are fetched by `ansible-galaxy` from a **pinned
git tag** in `ansible/requirements.yml` — not copy-pasted into this repo.

Why the published AMI by default:

- **No silent duplication.** Vendoring 6 roles and ~40 CIS controls into a
  second repo guarantees they drift. Whoever fixes a control upstream would
  have to remember this repo exists. The published-AMI path means upstream
  fixes arrive by rebuilding.
- **The hardening is already tested where it lives.** `hardened-al2023`
  gates its own publish on its own Goss suites. Re-running those here would
  be re-testing someone else's contract; this repo's suites test only what
  this repo changes (see "Testing").
- **Honest provenance.** The resulting AMI is tagged with the source AMI
  ID, so you can trace any access node back to the exact hardened base it
  came from.

Why `al2023-base` mode exists anyway:

- You may not run `hardened-al2023` and may not want to adopt it.
- You may have your own hardened AL2023 baseline — point the filter at it
  and leave `apply_upstream_hardening = false`.
- Building from the public AL2023 AMI in CI proves this repo's role works
  against an unhardened base, which is a genuinely useful regression test.

**Known limitation.** `hardened-al2023`'s own template is single-arch and
its published AMI is `x86_64` in most accounts. If you want `arm64` access
nodes in `hardened-ami` mode, you must first publish an `arm64`
`hardened-al2023` AMI (point its `source_ami_ssm_parameter` at the arm64
AL2023 parameter). Otherwise build arm64 in `al2023-base` mode. This is
documented rather than papered over, because a filter that silently matched
the wrong architecture would produce an AMI that fails to boot.

## Decision: what the access-node role actually changes

The upstream baseline is a *general-purpose* hardened server that
deliberately keeps SSH working. An access node is the opposite: SSH is the
thing we are removing. The `access_node` role is therefore mostly
subtraction.

| Change | Why |
|---|---|
| `systemctl disable --now sshd` **and** `systemctl mask sshd` | Disabled stops it starting at boot; masked stops anything (a package update, a well-meaning Ansible run, a human) starting it later. |
| Remove the `ssh` service from the firewalld `drop` zone | Upstream's `network` role explicitly allows SSH (`network_firewalld_allowed_services: [ssh]`). Leaving that in place would mean the image *claims* to be bastion-free while still permitting port 22 if sshd ever came back. This is the "replace any inherited firewall rule that allows SSH" requirement. |
| Delete `/root/.ssh/authorized_keys` and `/home/*/.ssh/authorized_keys` | No key should survive the bake. |
| Pre-seed `/etc/sudoers.d/ssm-agent-users` with a comment only | SSM Agent grants `ssm-user ALL=(ALL) NOPASSWD:ALL` when it first creates the account. Pre-creating the file with AWS's documented comment-only content means interactive sessions land as a genuinely unprivileged user. |
| Do **not** install database clients, `kubectl`, or other tooling | See "Decision: an empty node". |
| Write `/etc/bastion-free-ami/release` | Lets `scripts/verify` and the smoke test identify what they are talking to. |

### Why `mask` rather than removing `openssh-server`

Removing the package is tempting and slightly stronger. It is rejected
because **Packer provisions this image over SSH**. Uninstalling sshd
mid-build severs the communicator and every later provisioner fails,
including the Goss and Trivy gates that make the build trustworthy.

Masking achieves the same persistent outcome — on a booted instance from
this AMI, sshd cannot start, and port 22 does not listen — while leaving the
build's own connection intact. `docs/threat-model.md` notes the residual
difference: the `openssh-server` binary is present on disk, so a root-level
attacker who can unmask a unit could start it, but they would still face a
security group with no inbound rules.

### Consequence for the "a Goss test proves sshd is disabled" requirement

Goss runs on the build instance, which is *currently reachable over SSH* —
that is how Packer got there. So `tests/goss/goss_no_ssh.yaml` asserts the
**persistent** state that governs the baked AMI:

- `sshd` is not enabled, and `systemctl is-enabled sshd` reports `masked`
- the masked unit link points at `/dev/null`
- firewalld's `drop` zone does not list the `ssh` service
- no `authorized_keys` exists outside the build user's ephemeral one
- the sshd config that *would* apply denies root login and passwords

Asserting `running: false` during the build would be a test that can only
pass by breaking the build. Instead, "port 22 does not listen on a real
booted instance" is proven by `tests/smoke-test.sh`, which launches the AMI
and checks from inside over Session Manager. Both gates are wired into CI.
This split is deliberate and is called out in the README rather than hidden.

## Decision: an empty node

The requirement is that the AMI contains only what it needs. For an access
node, that is close to nothing:

- **SSM Agent** — the entire access path. Already in the base.
- **CloudWatch Agent** — ships OS logs off-box. Already in the base.
- Nothing else.

Specifically **no** `mysql`, `psql`, `redis-cli`, `kubectl`, `awscli`, or
`mongosh`. This surprises people, so the reasoning:

Port forwarding terminates the TCP connection *on the node* and hands the
bytes back to the engineer's laptop, where their own client runs. The node
never parses the protocol, so it does not need a client for it. Installing
one would mean:

- a larger attack surface and more CVEs to patch on the one instance that
  every engineer can reach;
- an invitation to run `psql` *in the session*, which moves query traffic
  off the laptop and into a shell — where the session log captures
  credentials typed at a prompt (see `docs/audit-evidence.md`);
- an implicit claim that the node is a workstation, which is how bastions
  accumulate state and become pets.

If a team genuinely needs a tool on the node, the honest answer is a
derived AMI built from this one, not a default that ships to everybody.

## Decision: `admin_space_left_action` on an access node

Upstream `hardened-al2023` sets `auditd_admin_space_left_action: halt`,
`disk_full_action: halt`, and `disk_error_action: halt`. Per CIS, a host
that can no longer guarantee its audit trail should stop rather than
silently lose events.

**On an access node this default is actively dangerous, and this project
overrides it.**

The access node *is the access path*. If its audit partition fills during
an incident — which is exactly when session volume and audit volume spike —
`halt` takes the instance down, and with it every engineer's route into the
VPC. You lose the ability to investigate at the moment you need it most.
The failure mode is self-reinforcing: more incident → more audit events →
partition fills → access dies → longer incident.

Worse, a hostile party who can generate audit events (anyone with a session)
has a denial-of-service primitive against the whole team's access.

The override, in `ansible/roles/access_node/defaults/main.yml`:

| Setting | Upstream | Here | Reason |
|---|---|---|---|
| `auditd_admin_space_left_action` | `halt` | `syslog` | Record loudly; stay reachable. |
| `auditd_disk_full_action` | `halt` | `rotate` | Losing the oldest audit records beats losing the access path. |
| `auditd_disk_error_action` | `syslog` | `syslog` | Unchanged. |
| `auditd_max_log_file_action` | `keep_logs` | `rotate` | `keep_logs` is what fills the partition in the first place. |

This is a real trade-off and it is a downgrade of audit-trail integrity, so
the mitigations are not optional in this design:

1. **The authoritative session record is off-box anyway.** Who connected to
   what and when lives in CloudTrail and CloudWatch Logs, neither of which
   is affected by the node's local disk. Local `auditd` is corroborating
   detail, not the primary evidence (`docs/audit-evidence.md` is explicit
   about which is which).
2. **The ASG replaces unhealthy nodes.** A node with a sick disk gets
   recycled; a halted one just sits there.
3. **Logs ship continuously**, so the window of locally-only-held audit
   data is small.
4. **An alarm, not a halt.** `session-logging` can raise a CloudWatch alarm
   on audit-disk pressure.

Teams whose compliance posture requires `halt` can set
`access_node_auditd_admin_space_left_action: halt` and accept the
availability consequence. The variable exists, the default does not pretend
the risk away, and `docs/threat-model.md` carries the same note.

## Decision: IAM scoping, and where AWS runs out of road

`terraform/modules/access-iam` builds one role per team. Each role gets:

- `ssm:StartSession` on `arn:aws:ec2:<region>:<account>:instance/*`,
  conditioned on `ssm:resourceTag/<key>` matching that team's tag — the
  pattern AWS documents for tag-scoped session access.
- `ssm:StartSession` on *only* the session document ARNs that team may use,
  with `"Bool": {"ssm:SessionDocumentAccessCheck": "true"}`. That condition
  forces the caller to name a document and forces IAM to evaluate access to
  it. Without it, a policy that grants the shell document also effectively
  permits any other document the caller can reach.
- `ssm:TerminateSession` and `ssm:ResumeSession` on
  `arn:aws:ssm:*:*:session/${aws:userid}-*`, so a user can only end their
  own session.
- `ssmmessages:OpenDataChannel` on the same `${aws:userid}` -scoped ARN.
- `kms:GenerateDataKey` on the session KMS key only (required when session
  data is KMS-encrypted).

### Per-team host and port allowlists: what AWS actually supports

The requirement is to allowlist remote hosts and ports per team "where AWS
supports it, and explain any limits". Here is the limit, stated plainly:

**IAM cannot condition on the parameters of `ssm:StartSession`.** There is
no condition key for the `host`, `portNumber`, or `localPortNumber`
parameters of `AWS-StartPortForwardingSessionToRemoteHost`. A team allowed
to use that document can forward to *any* host and port the node can reach.
That is a much bigger grant than it looks, and it is the single most
commonly missed detail in Session Manager designs.

The supported mechanism is indirect: **a session document is the unit of
authorization, so bake the target into the document.** A `Port` -type
session document carries `properties.host` and `properties.portNumber` as
fixed values rather than parameters. `access-iam` can therefore mint one
document per allowed target and grant each team only its own:

```
bfa-pf-payments-db    host=payments.cluster-xyz.rds.amazonaws.com  port=5432
bfa-pf-analytics-redis host=analytics.abc.cache.amazonaws.com      port=6379
```

The `payments` team's role lists only `document/bfa-pf-payments-db`, and
`SessionDocumentAccessCheck` makes that restriction bite. The engineer still
chooses their own `localPortNumber`, which is purely local and harmless.

Two honest caveats:

1. This is **one document per host/port pair**. It does not scale to
   hundreds of targets, and it is managed infrastructure, not an ACL you
   edit at runtime. For a handful of datastores per team — the common case —
   it works well.
2. If you grant a team the generic `AWS-StartPortForwardingSessionToRemoteHost`
   document *as well*, every allowlist above is moot. The module defaults to
   not granting it and says so in its variable description.

### MFA and IAM Identity Center

`access-iam` supports both, without pretending either is universal:

- **MFA**: an optional trust-policy condition
  (`aws:MultiFactorAuthPresent`) on assuming a team role, plus an optional
  `aws:MultiFactorAuthAge` bound. This works for IAM users and role
  chaining; it is a no-op for principals that arrive already federated.
- **IAM Identity Center**: the module emits permission *policies* that can
  be attached to a permission set, rather than assuming it owns the role
  trust relationship. Identity Center manages its own roles
  (`AWSReservedSSO_*`), and a module that tried to create them would fight
  the service. `aws:userid` -scoped session ARNs work correctly for
  federated principals, which is why they are used in preference to
  `aws:username` (which AWS documents as not working for federated IDs).

## Decision: session preferences are account-and-region global

This is the sharpest edge in the whole kit, so `session-logging` treats it
carefully.

Session Manager's logging, idle timeout, maximum duration, Run As, and KMS
settings live in **one SSM document per account per region**, named
`SSM-SessionManagerRunShell`. It is not per-team and not per-ASG. In most
AWS accounts it **already exists**, because someone opened the Session
Manager console and clicked Preferences once.

A Terraform module that unconditionally declared
`aws_ssm_document "SSM-SessionManagerRunShell"` would either fail with
`DocumentAlreadyExists` or — worse, if someone imported it carelessly —
silently replace an account-wide setting that other teams depend on.

So `session-logging` defaults to **not managing it**
(`manage_session_preferences = false`) and instead:

- emits the exact document content it *would* apply, as an output, so you
  can diff it against what you have;
- documents the `terraform import` command to adopt the existing document;
- when `manage_session_preferences = true`, requires you to additionally
  set `i_understand_preferences_are_account_wide = true`, so adopting a
  global setting is a deliberate two-key action rather than a default.

An alternative that avoids the problem entirely is also supported: set
`custom_preferences_document_name` to create a **differently named**
`Standard_Stream` document (e.g. `bfa-SessionManagerRunShell`) and have
`access-iam` grant teams that document instead. Preferences then apply only
to sessions started through this kit, and the account default is untouched.
This is the recommended path for shared accounts and is what the
`multi-team` example uses.

## Decision: logging, and what is not in the logs

Session logging is on by default: a customer-managed KMS key, a CloudWatch
Logs group with a defined retention, optional S3 archive with public access
blocked, versioning, and SSE-KMS.

The limitation that matters, verified against current AWS documentation:

> Logging isn't available for Session Manager sessions that connect through
> port forwarding or SSH. This is because SSH encrypts all session data
> within the secure TLS connection established between the AWS CLI and
> Session Manager endpoints, and Session Manager only serves as a tunnel for
> SSH connections.
> — *AWS Systems Manager User Guide, "Enabling and disabling session logging"*

So for the port-forwarding paths — which is how you reach RDS, ElastiCache,
internal HTTP, and the EKS API — **the session log records that a tunnel
existed, not what went through it.** You get, from CloudTrail and the
session record: principal, target instance, document used, start time, end
time, duration, source IP. You do not get the SQL.

This is stated in the README, in `docs/threat-model.md`, and in
`docs/audit-evidence.md`, because a reader who assumes otherwise will build
a control they do not have. Where you need statement-level visibility, the
answer is at the datastore: RDS audit logging / Performance Insights,
ElastiCache slow logs, ALB access logs, EKS audit logs. Those are named per
access path in `docs/access-paths.md`.

Shell sessions on the access node *are* fully logged, including keystrokes
and output, which is its own hazard: a credential typed at a prompt lands in
the log. `docs/audit-evidence.md` carries AWS's `stty -echo` guidance.

## Decision: VPC endpoints

`vpc-endpoints` creates only what current AWS documentation requires for
this use case, because interface endpoints cost roughly $7.30/month each per
AZ and an over-eager module is a recurring bill.

| Endpoint | Type | Default | Why |
|---|---|---|---|
| `ssm` | Interface | on | The Systems Manager service endpoint. |
| `ssmmessages` | Interface | on | Required for Session Manager's data channel. |
| `s3` | Gateway | on | SSM Agent updates itself from S3. Gateway endpoints are free. |
| `ec2messages` | Interface | **off** | Legacy. From SSM Agent 3.3.40.0 AWS uses `ssmmessages` whenever available. Enable only for older agents. |
| `kms` | Interface | on when session KMS encryption is on | Needed for `kms:GenerateDataKey`. |
| `logs` | Interface | on when CloudWatch logging is on | Needed to ship session and OS logs. |
| `ec2` | Interface | **off** | Only required for VSS-enabled snapshots, which this kit does not use. |

Notably **not** created: `sts`, `ecr`, `secretsmanager`. Nothing in the
access path calls them. Add them in your own configuration if your
workloads need them.

The `private-subnets` example wires these up with no NAT gateway at all,
which is also the cheapest correct configuration: three interface endpoints
beat one NAT gateway on cost and reduce egress exposure to zero.

## Decision: EICE is off by default

`terraform/modules/eice` creates an EC2 Instance Connect Endpoint, and
`enabled` defaults to `false`.

EICE is the right tool for exactly one situation: a tool that *must* speak
real SSH — `rsync`, `scp`, `ssh -D`, an IDE remote-development plugin, an
appliance that only knows SSH. Session Manager's `AWS-StartSSHSession` can
also do this, but EICE does it without an SSM Agent on the target.

The cost is explicit and is why it is off:

- **It reintroduces SSH on the target.** The target's security group must
  allow inbound TCP 22 *from the EICE* (or from the endpoint's security
  group). That is an inbound rule, on port 22, on a host this kit otherwise
  guarantees has neither. It is narrower than a public bastion — the source
  is an AWS-managed endpoint, not the internet — but it is not nothing, and
  the access node's sshd is masked, so **EICE cannot target the access node
  as shipped.** It is for *other* hosts that genuinely need SSH.
- **Key management comes back.** You are back to managing an SSH key or
  relying on EC2 Instance Connect's ephemeral key push.
- **Traffic contents are not logged**, same as port forwarding. CloudTrail
  records the `OpenTunnel` call.

What EICE does support, and the module exposes, is genuinely good IAM
scoping — better than Session Manager's for this purpose:
`ec2-instance-connect:OpenTunnel` honours the condition keys
`ec2-instance-connect:remotePort`, `ec2-instance-connect:privateIpAddress`,
and `ec2-instance-connect:maxTunnelDuration`. So unlike port forwarding, you
*can* allowlist port and destination IP directly in IAM. The module's
variables map one-to-one onto those conditions.

## Decision: self-healing must not need a human with SSH

The access node is the thing you use to fix problems, so it must not need
itself to recover. Therefore:

- An **Auto Scaling Group**, not a standalone instance. `min_size` ≥ 1 in
  the default configuration; EC2 health checks replace a failed node with
  no human involvement.
- **Multi-AZ** by default — a list of private subnets across AZs. Losing an
  AZ costs you capacity, not access.
- **Instance refresh** for AMI rollouts, so a new AMI rolls out by updating
  `ami_id` and letting the ASG cycle nodes, rather than by anyone logging
  in.
- **No user data that can fail open.** The node is functional as baked; user
  data is limited to writing an identifying file. If user data fails, the
  node is still reachable, because reachability depends on SSM Agent and the
  instance role, both of which are baked in.
- **Optional scale-to-zero schedule** for teams that only need access
  during business hours. It is a cost control and it is off by default,
  because a schedule that scales access to zero is also a schedule that
  locks you out at 19:00 during an incident. When enabled, the module
  outputs the one-line command to scale back up — which needs only
  `autoscaling:SetDesiredCapacity`, not SSH.

The lockout runbook in `docs/migrating-from-a-bastion.md` assumes none of
the above works and starts from an empty account.

## Testing

| Gate | What it proves | Blocking |
|---|---|---|
| `tests/goss/goss.yaml` | Base assumptions hold on the source AMI (SSM Agent present and enabled, IMDSv2 required). | yes |
| `tests/goss/goss_no_ssh.yaml` | sshd disabled + masked, no SSH firewall rule, no authorized keys, no key-based path back in. | yes |
| `tests/goss/goss_access_node.yaml` | `ssm-user` has no sudo grant, auditd overrides applied, no database clients installed, release file written. | yes |
| `tests/goss/goss_advisory.yaml` | Things worth knowing, never auto-failed. | no |
| Trivy filesystem scan | No CRITICAL vulnerability and no secret baked into the image. | yes, in CI before publish |
| `terraform test` | Module variable validation and the invariants that matter (no public IP, no inbound rules, IMDSv2, encryption, retention set). | yes |
| `tests/scripts/test-verify-readonly.sh` | `scripts/verify` makes no AWS write call. | yes |
| `tests/smoke-test.sh` | A real booted instance has no listener on 22 and is reachable over Session Manager. | manual / nightly |

The `terraform test` suites run with `command = plan` and mocked providers
where possible, so CI needs no AWS credentials for pull requests. That is
also why **AMIs are never built on pull requests** — see `docs/design.md`
above on provenance, and the two-workflow split in `.github/workflows/`.

## Pinning

Everything third-party is pinned, because a kit that controls access to a
VPC is a supply-chain target:

- Packer plugins: `required_plugins` with explicit version constraints.
- Terraform providers: `>= 6.0.0, < 7.0.0` on `hashicorp/aws`, with
  `required_version >= 1.7.0` so OpenTofu is supported too.
- GitHub Actions: pinned by commit SHA with the version in a trailing
  comment.
- Goss and Trivy: pinned version **and** SHA256 checksum, verified before
  the binary is executed.
- Upstream Ansible roles (in `al2023-base` mode): pinned git tag.

## Supporting evidence, not compliance

`docs/audit-evidence.md` maps what this kit produces onto the questions SOC
2 and ISO 27001 auditors actually ask. It is supporting evidence for a
control you operate — it is not a certification, not an attestation, and no
open-source template can be one on your behalf. Deploying this kit does not
make an account compliant.
