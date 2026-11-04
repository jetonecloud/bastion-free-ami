# bastion-free-ami

A hardened Amazon Linux 2023 AMI and a Terraform kit that let you delete
your public bastion. Engineers still reach private RDS instances,
ElastiCache clusters, internal services, and private EKS endpoints —
through AWS Systems Manager Session Manager, authorised by IAM, with
every session recorded in CloudTrail.

No public IP. No inbound security group rules. No SSH keys. No static
AWS credentials on the access nodes.

It's open source (Apache-2.0), and it builds in your account.

## What "bastion-free" means, precisely

It means **no public bastion and no inbound access**: nothing listens,
nothing is reachable from the internet, and there is no key to steal or
rotate.

It does **not** mean "no instance". Reaching a private RDS endpoint
still requires something inside the VPC to terminate the TCP connection
and forward it. Session Manager port forwarding needs a managed node to
forward *through*, and AWS offers no serverless way to tunnel arbitrary
TCP into a private subnet.

So this kit still runs an instance. It's just an instance with no attack
surface reachable from the internet, no credential to steal, no state
worth keeping, and an IAM boundary instead of a network one. The
instance is replaced automatically and nobody logs into it to fix it.

## The limitation you need to know before you start

**Port-forwarding traffic contents are not logged.** AWS:

> Logging isn't available for Session Manager sessions that connect
> through port forwarding or SSH.

That covers RDS, ElastiCache, internal HTTP, and the EKS API — every
path except an interactive shell. What you get is the session record:
principal, target instance, session document, start, end, duration,
source IP. What you don't get is the SQL.

So: **all access is recorded; session content is captured for shell
sessions only.** If a control you rely on needs statement-level
visibility, it has to come from the datastore's own audit log —
[`docs/access-paths.md`](docs/access-paths.md) names the setting for
each one. If you tell an auditor "everything is logged", the first
follow-up question will go badly.

Shell sessions *are* fully logged, keystrokes included — which means a
password typed at a prompt lands in CloudWatch Logs. The AMI warns
about this at every login. [`docs/threat-model.md`](docs/threat-model.md)
has the full list of limits; there are ten and they're all stated
plainly.

## Getting started

Prerequisites: an AWS account, [Packer](https://developer.hashicorp.com/packer)
≥ 1.10, [Ansible](https://docs.ansible.com/) ≥ 2.16, Terraform ≥ 1.7
(or OpenTofu ≥ 1.7), and the
[Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
on your own machine.

```sh
git clone https://github.com/jetonecloud/bastion-free-ami.git
cd bastion-free-ami

# 1. Build the AMI. Blocking Goss suites and a Trivy scan gate it.
make init
cp packer/example.pkrvars.hcl packer/local.pkrvars.hcl
$EDITOR packer/local.pkrvars.hcl
make build ARCH=x86_64

# 2. Deploy. Start with the minimal example and read it -- it is
#    commented as a walkthrough.
cd terraform/examples/minimal
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars
terraform init && terraform apply

# 3. Check what you actually got. Read-only; makes no AWS writes.
cd ../../..
./scripts/verify --tag BastionFreeAccess=shared

# 4. Connect.
./scripts/connect shell
```

Everything except step 1 runs without spending money. `make test` and
`make test-scripts` need no AWS credentials at all.

## Connecting

`scripts/connect` is a thin wrapper around `aws ssm start-session`. It
checks your prerequisites, finds a healthy node by tag, **prints the AWS
command it's about to run**, and runs it. It accepts only explicit
targets and refuses to guess endpoints — after a while you won't need it.

```sh
./scripts/connect list                    # healthy nodes
./scripts/connect shell                   # interactive shell
./scripts/connect forward --document bfa-pf-payments-db --local-port 5432
./scripts/connect forward --port 8080 --local-port 8080 --dry-run
```

Each path has a gotcha, and
[`docs/access-paths.md`](docs/access-paths.md) has the real fix for each
— not the `sslmode=require` advice that quietly gives up server
authentication:

| Path | What breaks | The fix |
|---|---|---|
| Shell | Keystrokes are logged | `stty -echo; read VAR; stty echo` |
| RDS / Aurora | TLS hostname via `localhost` | `/etc/hosts`, or libpq `host` + `hostaddr` |
| IAM DB auth | Token signed for the real host | Generate it for the real hostname |
| ElastiCache | TLS hostname; cluster mode | `--sni`; one tunnel per shard |
| Internal HTTP | TLS **and** `Host` routing | `curl --resolve` |
| Private EKS | API cert hostname | `/etc/hosts` + real name in kubeconfig |

## What's in the box

```
packer/                  One HCL2 template, x86_64 and arm64
ansible/roles/access_node/   The only role this repo owns
tests/goss/              Blocking suites + advisory
tests/smoke-test.sh      Boots the AMI, proves port 22 is closed
terraform/modules/
  access-node/           Launch template + multi-AZ ASG
  access-iam/            Per-team roles, tag + document scoping
  session-logging/       KMS, CloudWatch Logs, S3 archive, preferences
  vpc-endpoints/         For private subnets with no NAT
  eice/                  EC2 Instance Connect Endpoint (off by default)
terraform/examples/      minimal · private-subnets · multi-team
scripts/connect          Find a node, start a session
scripts/verify           Read-only posture check
docs/                    Design, access paths, threat model, migration
```

## The AMI

Amazon Linux 2023, `x86_64` and `arm64`, from one Packer template.

By default it builds **on top of
[`hardened-al2023`](https://github.com/jetonecloud/hardened-al2023)**'s
published AMI rather than vendoring its CIS-aligned roles, so upstream
fixes arrive by rebuilding instead of by someone remembering this repo
exists. One var file switches to building from the public AL2023 base
with those roles applied from a pinned tag —
[`docs/design.md`](docs/design.md) explains the choice and how to change
it.

On top of that baseline, this role mostly *subtracts*:

- **`sshd` and `sshd.socket` disabled and masked**, the mask verified
  as a `/dev/null` symlink.
- **The inherited firewalld rule allowing SSH removed.** The upstream
  baseline explicitly permits port 22 so a CIS run can't lock anyone
  out; on an access node that rule is exactly what we're removing.
- **A deny-all `sshd_config` drop-in**, so if someone unmasks `sshd` in
  an emergency, what comes back up isn't a soft target.
- **`ssm-user`'s sudo grant pre-empted** using AWS's documented
  comment-only sudoers file, with a build failure if any other drop-in
  grants it. Interactive sessions are genuinely unprivileged.
- **No database clients, `kubectl`, or broad tooling.** Port forwarding
  terminates TCP on the node and hands the bytes to your own client, so
  the node never parses the protocol and doesn't need one. A Goss check
  enforces their absence.

Plus, hardcoded in the Packer source block rather than left as variables
you could switch off: **IMDSv2 required with hop limit 1**, an
**encrypted root volume and snapshot**, and **no key pair** — Packer
mints a throwaway one per build and discards it.

### How "sshd is disabled" is actually proven

Worth being precise, because it's the project's central claim.

Packer provisions the image **over SSH** — that's how Ansible and the
tests get there — so `sshd` is necessarily running while Goss executes.
A `running: false` check could only pass by breaking the build that
produces the AMI.

So the work is split, and both halves gate CI:

- **`tests/goss/goss_no_ssh.yaml`** asserts the *persistent* state that
  governs a booted instance: masked via a `/dev/null` unit link, not
  enabled, no firewalld rule for `ssh` or port 22 in any zone, no
  stray `authorized_keys`, no baked host keys.
- **`tests/smoke-test.sh`** asserts the *runtime* state: it boots a real
  instance from the finished AMI behind a security group it first
  verifies has no inbound rules, waits for Session Manager
  registration, then proves from inside that nothing listens on 22 and
  `ssm-user` can't escalate.

## Access control

`access-iam` builds one role per team. Access to a node is scoped by
tag; access to a *capability* is scoped by session document:

```hcl
teams = {
  payments = {
    access_tag_value       = "payments"
    trusted_principal_arns = ["arn:aws:iam::111122223333:role/AWSReservedSSO_Payments_abc"]
    allow_shell            = true

    forward_targets = {
      db = { host = "payments.cluster-abc.us-east-1.rds.amazonaws.com", port = 5432 }
    }
  }

  analytics = {
    access_tag_value = "shared"
    allow_shell      = false   # queries datastores, no reason to run commands
    forward_targets  = {
      warehouse = { host = "analytics-ro.cluster-ro-def.rds.amazonaws.com", port = 5432 }
    }
  }
}
```

### Why per-target documents, and not an IAM condition

Because **IAM can't do it.** There's no condition key for the `host` or
`portNumber` parameters of `ssm:StartSession`, so a team granted
`AWS-StartPortForwardingSessionToRemoteHost` can forward to anything the
node can reach — which in a private subnet is most of the VPC, including
other teams' databases. Policies that look tightly scoped routinely have
this hole in them.

What IAM *can* authorise is a document. So each `forward_targets` entry
becomes its own `Port` session document with the host and port as
**fixed properties, not parameters** — the caller can't override them.
Three things make that hold:

1. `ssm:SessionDocumentAccessCheck`, which forces the caller to name a
   document and forces IAM to evaluate access to it.
2. An explicit `Deny` on `AWS-StartPortForwarding*`, so a team can't
   escape its allowlist by naming a generic document.
3. An explicit `Deny` on `AWS-StartSSHSession`, which would bypass
   session logging entirely.

`terraform output warnings` tells you when a configuration has defeated
itself, and `team_document_arns` is the authoritative answer to "what
can this team actually reach". The limits of the approach — one document
per host/port pair — are in
[the module README](terraform/modules/access-iam/README.md).

Sessions are scoped to the caller with `${aws:userid}` rather than
`${aws:username}`, which AWS documents as not working for federated
identities. MFA is a trust-policy condition, which is effective for IAM
users and role chaining and a no-op for already-federated principals —
said out loud because "we require MFA" is a claim people rely on.

### Getting root, when you need it

There isn't any sudo on `ssm-user`, on purpose. Elevation is a
**separate IAM role** tagged `SSMSessionRunAs=ec2-user`, so sessions
started by that role land as a user that can sudo.

That's deliberately not a sudoers rule: assuming the role is a distinct,
MFA-gated `sts:AssumeRole` event, so "who had root on the access node,
and when" is answerable from CloudTrail rather than from a `sudoers`
file nobody reads.

## Logging

On by default: a customer-managed KMS key, a CloudWatch Logs group with
a **mandatory** retention (`0`/never-expire is rejected — an unbounded
audit log is a cost and a liability), and an optional S3 archive with
public access blocked on all four dimensions, SSE-KMS, and versioning.

One sharp edge, handled carefully: **Session Manager preferences are one
document per account per region**, usually already present because
somebody clicked Preferences in the console once. So
`session-logging` defaults to **not managing it**, emits the content it
*would* apply so you can diff it, documents the `terraform import`
path, and requires a second acknowledgement variable before touching
it. The recommended alternative is a separately named document, which
leaves the account default alone — that's what the `multi-team` example
uses.

[`docs/queries/`](docs/queries/) has CloudTrail, Logs Insights, and
Athena queries for who connected, to what, when, and for how long.
CloudTrail is the one that answers the audit question, because the log
group only has shell sessions.

## Checking your posture

```sh
./scripts/verify --tag BastionFreeAccess=shared \
                 --log-group /aws/ssm/bfa/sessions \
                 --s3-bucket bfa-session-logs-111122223333
```

Public IPs, inbound rules, anything reaching port 22 (including rules
that merely span it), key pairs, IMDSv2 and hop limit, EBS encryption,
logging destination, KMS, retention, and whether a healthy node exists
at all. `--json` for machine-readable output.

It makes **no AWS write calls**, and that's tested rather than asserted:
every call goes through a gate that rejects non-read operations, a
static pass rejects write verbs and calls that bypass the gate, and a
behavioural test runs the real script against a recording fake `aws` on
`PATH` and asserts every invocation was a read. People run this in
production during incidents with elevated credentials, so "it's
read-only" needs to be a fact.

## Moving off your bastion

[`docs/migrating-from-a-bastion.md`](docs/migrating-from-a-bastion.md)
is a staged migration that never leaves you without a way in: inventory,
deploy alongside, move and test each path, confirm logs, close inbound
with **port 22 last**, hold a defined observation period with a
rehearsed rollback, then decommission and revoke the keys.

It includes a pre-cutover checklist and a lockout recovery runbook with
six escalating steps, none of which needs SSH. The inventory stage is
the longest on purpose — it has the commands to find the cron job on the
bastion, the CI pipeline tunnelling through it, and the vendor CIDR
nobody remembers, and it's explicit that machine consumers usually
shouldn't move to an access node at all.

## Cost

Roughly, in `us-east-1`:

| | Monthly |
|---|---|
| 1× `t3.small` access node, on demand | ~$15 |
| 2× `t3.small` (multi-AZ, recommended) | ~$30 |
| AMI snapshot storage, per version kept | ~$0.80/GiB |
| CloudWatch Logs ingest | $0.50/GiB |
| KMS key | $1 |
| **With NAT** (`minimal`) | **+~$33** plus data processing |
| **With VPC endpoints** (`private-subnets`) | **+~$58** for 4 endpoints × 2 AZs |

The endpoint route looks more expensive than one NAT gateway until you
run one NAT per AZ for availability — and it removes internet egress
entirely. The weekly rebuild produces a new AMI every week, so set a
pruning policy.

A build costs a few cents. `make test` and `make test-scripts` cost
nothing.

## Compliance

[`docs/audit-evidence.md`](docs/audit-evidence.md) maps what this
produces onto SOC 2 and ISO 27001 criteria, including the gaps and how
to describe them.

It's **supporting evidence, not compliance.** Deploying this doesn't
make an account compliant, certified, or attested, and no open-source
template can be on your behalf. Your auditor assesses your control
environment; this gives you something to show them.

## Contributing, security, license

- [CONTRIBUTING.md](CONTRIBUTING.md) — and please check AWS
  documentation rather than memory; several decisions here exist
  because the obvious assumption was wrong.
- [SECURITY.md](SECURITY.md) — please don't open a public issue for a
  security problem. Note what's out of scope: the port-forwarding
  logging gap is AWS behaviour, documented here, not a bug.
- Apache 2.0, see [LICENSE](LICENSE).
- [CHANGELOG.md](CHANGELOG.md) for release history.

## Want help removing yours?

That's what we do at [Jet1](https://jetonecloud.com): deploys, AWS
infrastructure, cost work, and on-call, with an SLA, and you own
everything we build. [Book a 20-minute call](https://jetonecloud.com/book).
