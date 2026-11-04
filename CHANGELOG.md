# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/) for
its tagged releases (`vMAJOR.MINOR.PATCH`), which the pipeline uses as
the AMI's version tag.

## [Unreleased]

## [0.1.0] - 2026-11-04

Initial release.

### Added

#### AMI

- Packer HCL2 template (`packer/`) building `x86_64` and `arm64` access
  node AMIs from one definition, with two source modes: the published
  `hardened-al2023` AMI (default) or the public Amazon Linux 2023 base
  with the upstream roles applied from a pinned git tag.
- IMDSv2 required with hop limit 1, encrypted root volume and snapshot,
  and no EC2 key pair — hardcoded in the source block rather than
  exposed as variables.
- `access_node` Ansible role: `sshd` and `sshd.socket` disabled and
  masked, the inherited firewalld rule allowing SSH removed, a deny-all
  `sshd_config` drop-in for the case where someone unmasks it,
  `ssm-user`'s sudo grant pre-empted using AWS's documented
  comment-only sudoers file, and a build-time failure if any other
  drop-in grants it.
- `auditd` disk policy overridden from the upstream CIS default of
  `halt`, with the reasoning recorded on the image itself at
  `/etc/audit/README.bastion-free-ami`.
- No database clients or broad tooling, enforced by a Goss check rather
  than left to convention.
- Three blocking Goss suites plus an advisory one, and a Trivy
  vulnerability, secret, and misconfiguration scan.
- `tests/smoke-test.sh`: boots a real instance from the built AMI behind
  a security group it first verifies has no inbound rules, waits for
  Session Manager registration, then proves from inside that nothing
  listens on port 22 and `ssm-user` cannot escalate.
- AMI ID published to `/bastion-free-ami/<region>/latest` and
  `/bastion-free-ami/<region>/<arch>/latest`.

#### Terraform

- `access-node`: launch template and multi-AZ ASG, private subnets only,
  no public IP, egress-only security group with no way to add an ingress
  rule, instance refresh with auto-rollback for AMI rollouts, an
  optional scale-to-zero schedule (off by default), and an instance role
  granting only the five Session Manager actions AWS documents as the
  minimum plus scoped log writes.
- `access-iam`: per-team roles or policies, scoped by `ssm:resourceTag`
  and by session document with the `ssm:SessionDocumentAccessCheck`
  condition. Per-team host and port allowlists implemented as one `Port`
  session document per target, with explicit denies on the generic
  forwarding and SSH documents. MFA conditions, IAM Identity Center
  support, and the `SSMSessionRunAs` elevation path.
- `session-logging`: KMS key, CloudWatch Logs with a mandatory retention,
  optional S3 archive with public access blocked, SSE-KMS, versioning
  and lifecycle rules, and session preferences that default to
  unmanaged with a documented import path.
- `vpc-endpoints`: only the endpoints current AWS docs require, with
  `ec2messages` and `ec2` off by default and a cost estimate output.
- `eice`: EC2 Instance Connect Endpoint, off by default behind two
  acknowledgement variables.
- Examples: `minimal`, `private-subnets`, `multi-team`.
- `terraform test` suites for `access-node`, `access-iam`, and
  `session-logging`, running against mocked providers so pull requests
  need no AWS credentials.

#### Scripts

- `scripts/connect`: thin AWS CLI wrapper that checks prerequisites
  (including the Session Manager plugin), finds a healthy node by tag,
  prints the command it will run, and accepts only explicit targets.
- `scripts/verify`: read-only posture check for public IPs, inbound
  rules, port 22, key pairs, IMDSv2, encryption, logging, retention, and
  node availability. Its read-only property is enforced by a gate
  function and proven by static, gate, and behavioural tests.

#### Documentation

- `docs/design.md` — architecture and every significant decision,
  including how this reuses `hardened-al2023`.
- `docs/access-paths.md` — commands and the real fix for the TLS
  hostname problem on each path.
- `docs/threat-model.md` — ten named limitations with residual risk.
- `docs/audit-evidence.md` — SOC 2 and ISO 27001 mapping, explicitly as
  supporting evidence rather than compliance.
- `docs/migrating-from-a-bastion.md` — staged migration, pre-cutover
  checklist, and lockout recovery runbook.
- `docs/queries/` — CloudTrail, Logs Insights, and Athena queries.
- `docs/iam-policy.json` / `.md` — pipeline and instance role policies.

#### CI/CD

- `validate.yml` on pull requests: formatting, validation, Terraform and
  OpenTofu tests, TFLint, ansible-lint, yamllint, ShellCheck, shfmt,
  Trivy, and Checkov. No AWS credentials and no `id-token`.
- `pipeline.yml` on main, tags, and weekly: OIDC-authenticated build,
  Goss gate, Trivy gate, then publish. No `pull_request` trigger, and a
  guard job that fails if reached from one.

### Known limitations

Documented rather than implied — see
[docs/threat-model.md](docs/threat-model.md):

- **Port forwarding and SSH session contents are not logged by AWS.**
  CloudTrail records that a session happened, not what passed through
  it. This affects every path except an interactive shell.
- Shell session logs capture keystrokes, so credentials typed at a
  prompt land in the log group.
- IAM has no condition key for `ssm:StartSession` port-forwarding
  parameters; allowlists are enforced via per-target session documents.
- `ssm:DescribeSessions` cannot be scoped to a caller's own sessions.
- `openssh-server` remains installed, masked and disabled, because
  Packer provisions the image over SSH.
- `arm64` in the default source mode needs an `arm64`
  `hardened-al2023` AMI to exist first.

[Unreleased]: https://github.com/jetonecloud/bastion-free-ami/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/jetonecloud/bastion-free-ami/releases/tag/v0.1.0
