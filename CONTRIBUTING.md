# Contributing

Thanks for considering a contribution. This kit controls how people
reach private AWS resources, and other people will run it against real
accounts — please weigh changes accordingly.

## Ground rules

- **Never weaken a hard requirement.** No public IPs, no inbound
  security group rules, no SSH keys, no static credentials on access
  nodes, IMDSv2 required with hop limit 1, encrypted volumes, no
  secrets in the image. These are hardcoded rather than variables on
  purpose, and `terraform test` asserts them. A PR that makes one
  configurable needs a very good argument.

- **Check AWS documentation, don't rely on memory.** This project's
  value is in getting the AWS details right — which condition keys
  exist, which endpoints are required, what is actually logged. Link
  the AWS doc page in your PR description for anything behavioural.
  Several of the design decisions here exist *because* the obvious
  assumption was wrong.

- **Be honest about limits.** If AWS cannot do something, say so
  plainly and say what the workaround costs. The port-forwarding
  logging gap and IAM's inability to condition on forwarding
  parameters are documented in the README, the threat model, the module
  READMEs, and as module *outputs*, because a reader who assumes
  otherwise builds a control they do not have. Keep that standard.

- **Never claim compliance.** "Supporting evidence for SOC 2 / ISO
  27001 reviews", never "SOC 2 compliant" or "certified". No
  open-source template can be compliant on someone's behalf.

- **Test what you claim.** "Implemented" with no test backing it is not
  implemented. Add a Goss check, a `terraform test` assertion, or a
  script test for anything you add.

- **Default to safe, not maximal.** If a control has a real chance of
  breaking a common setup, put it behind an off-by-default variable
  with a description explaining the trade-off — see `eice` and the
  scale-to-zero schedule. Do not make it unconditional.

- **Explain every wildcard.** A `Resource: "*"` or a broad action needs
  a comment saying why it is unavoidable and what bounds it instead.
  Several exist in this repo and each is commented; follow that
  pattern. Same for every `.trivyignore` entry and Checkov skip.

- **Do not add tooling to the AMI.** The access node forwards TCP and
  does not parse the protocols it forwards, so a database client there
  is pure attack surface on the one host everyone can reach.
  `goss_access_node.yaml` asserts their absence. If you genuinely need
  one, build a derived AMI.

## Development

Nothing below needs AWS credentials except `make build`.

```bash
make init          # packer plugins + ansible collections
make fmt           # format packer, terraform, and shell sources
make lint          # ansible-lint, yamllint, shellcheck, tflint
make validate      # packer + terraform validate
make test          # terraform test (mocked providers, no credentials)
make test-scripts  # prove scripts/verify is read-only
make scan          # trivy config + secret scan
```

Everything is also tested with OpenTofu, because the project claims
support for it:

```bash
make validate TF=tofu
make test TF=tofu
```

Building an AMI needs real credentials and costs a few cents:

```bash
cp packer/example.pkrvars.hcl packer/local.pkrvars.hcl
$EDITOR packer/local.pkrvars.hcl
make build ARCH=x86_64
```

## The two things most likely to trip you up

### 1. The Goss suite cannot assert `sshd` is not running

Packer provisions the image **over SSH**, so `sshd` is necessarily
running while Goss executes. `goss_no_ssh.yaml` therefore asserts the
*persistent* state that governs a booted instance — masked, disabled,
no firewall rule, `/dev/null` unit link — and `tests/smoke-test.sh`
asserts the runtime state on a real instance.

If you are tempted to "fix" this by adding `running: false`, read the
header comment in that file first. The build would fail by design.

### 2. Session preferences are account-wide

`SSM-SessionManagerRunShell` is one document per account per region and
usually already exists. `session-logging` defaults to not managing it
and requires a second acknowledgement variable to adopt it. Do not
simplify that away — it exists because overwriting it changes session
behaviour for teams unrelated to this kit.

## Pull requests

1. **One concern per PR.** The module split is a good guide.
2. **Update the docs in the same PR.** If you change behaviour, update
   the module README, and `docs/design.md` if you changed a decision.
   If you discover an AWS limit, add it to `docs/threat-model.md`.
3. **Add or update a test.** See "Test what you claim".
4. **Say what you tested against** — region, architecture, whether you
   ran a full `packer build`, whether you ran the smoke test.
5. **CI must pass.** `validate.yml` runs on your PR and needs no AWS
   credentials. The AMI build (`pipeline.yml`) deliberately does not
   run on pull requests; a maintainer can trigger it manually.

### Commit messages

Say what changed and why, in the imperative. The "why" matters more
than the "what" here — most of this repo's value is in decisions, and a
future reader needs the reasoning.

## Good first contributions

Genuinely useful, deliberately left out:

- **A Windows access node.** Session Manager supports Windows; this kit
  is Linux-only. Needs its own hardening role and Goss suite.
- **A `terraform test` suite for `vpc-endpoints` and `eice`.** The
  other three modules have one.
- **An AWS Config rule or Security Hub control** that continuously
  checks what `scripts/verify` checks on demand.
- **Automated session log review** — a Lambda that runs the
  `docs/queries/` Logs Insights queries on a schedule and posts
  anomalies.
- **An Athena/Glue table resource** in `session-logging`, so the S3
  archive is queryable without the manual DDL in
  `docs/queries/athena-session-logs.sql`.
- **A `kubectl` plugin or wrapper** that sets up the EKS tunnel and
  kubeconfig correctly, since that path has the most moving parts.
- **Multi-account support** — a module for the hub-and-spoke pattern
  where access nodes live in one account and targets in others.

## Reporting bugs vs. security issues

Regular bugs: open a GitHub issue.

Security issues — credential exposure, an auth bypass, a way to reach a
node you should not, a pipeline trust-boundary weakness, or a control
that silently fails to apply: see [SECURITY.md](SECURITY.md). Please do
not open a public issue.
