# Security Policy

## Supported versions

This project ships as source — a Packer template, Ansible role, and
Terraform modules — not as a running service, so there is no
"supported version" in the usual sense. Security fixes land on `main`
and are called out in [CHANGELOG.md](CHANGELOG.md).

If you built an AMI from an older commit, **rebuild from current
`main`** to pick up fixes, then let the ASG's instance refresh roll it
out. The pipeline's weekly schedule does this for OS packages
automatically.

## Reporting a vulnerability

**Please do not open a public GitHub issue for a security
vulnerability.**

Preferred: GitHub's private vulnerability reporting for this repository
(**Security** tab → **Report a vulnerability**). This reaches
maintainers without disclosing the issue publicly.

Alternative: email **security@usejetone.com** with:

- a description of the issue and its impact
- steps to reproduce — a minimal Terraform or Packer diff is ideal
- any suggested remediation

We aim to acknowledge within 5 business days and to agree a disclosure
timeline with you before any public write-up.

## What counts as a security issue here

**In scope:**

- A way to reach an access node you should not be able to reach —
  bypassing the `ssm:resourceTag` condition, the session document
  allowlist, or the `${aws:userid}` session scoping.
- A way to escape a team's port-forwarding allowlist, other than the
  documented `allow_unrestricted_forwarding` opt-in.
- A privilege escalation on the access node: anything that gives an
  interactive session root without going through the documented,
  separately audited `SSMSessionRunAs` role.
- A control this project claims to apply that silently fails to apply —
  particularly anything in the hard requirements list in the README.
- A Packer, Ansible, or Terraform change that could leak credentials,
  tokens, or SSH keys into an AMI, a build log, a CI artefact, or a
  Terraform state file.
- A pipeline change that weakens the OIDC trust boundary, allows an
  AMI to be published without passing the Goss and Trivy gates, or
  allows a pull request to trigger a build.
- A way to make `scripts/verify` perform an AWS write call, or to make
  it report a passing posture that is not actually passing.
- A pinned dependency (Goss, Trivy, a Packer plugin, a GitHub Action)
  with a known exploitable vulnerability.

**Out of scope** — please use regular issues or PRs:

- Limitations already documented in
  [docs/threat-model.md](docs/threat-model.md). In particular: **port
  forwarding and SSH session contents are not logged.** That is AWS
  behaviour, it is documented in four places in this repo, and it is
  not a vulnerability in this project. Reports of it will be closed
  with a pointer to the threat model.
- `openssh-server` being present on the image. It is masked and
  disabled, the reason it is not uninstalled is documented, and the
  advisory Goss suite reports it.
- `auditd` not halting on a full audit partition. This is a documented,
  deliberate override with stated reasoning and an override variable.
- Vulnerabilities in upstream Amazon Linux 2023 packages — report those
  to AWS. If a CVE is fixed upstream and this project's weekly rebuild
  has not picked it up, that *is* worth an issue.
- Misconfigurations in a deployment that departs from the documented
  defaults — for example granting
  `allow_unrestricted_forwarding = true` and then finding a team can
  forward anywhere. The module warns about exactly that.
- Security issues in `hardened-al2023` itself. Report those to
  [that repository](https://github.com/jetonecloud/hardened-al2023).

## Our own security posture

Things worth knowing if you are assessing this repo as a supply-chain
dependency:

- **No AMI is built on a pull request.** `pipeline.yml` has no
  `pull_request` trigger, every job additionally guards on the event
  name, and a first job fails loudly if it is ever reached from a PR.
- **CI uses OIDC**, not static access keys. No AWS credential is stored
  as a repository secret.
- **PR validation needs no credentials at all.** `validate.yml` has
  `contents: read` and no `id-token`, so it cannot assume an AWS role
  even if a step tried.
- **GitHub Actions are pinned by commit SHA**, with the version in a
  trailing comment.
- **Goss and Trivy are pinned by version and verified against the
  publisher's published checksum** before the binary is executed.
- **Terraform providers are pinned** with an upper bound.
- **Upstream Ansible roles are pinned to a git tag**, and the fetch
  script fails if an expected role has disappeared rather than building
  a less-hardened image quietly.
- **The publish job depends on both gates.** An AMI with a blocking
  Goss failure, a CRITICAL vulnerability, or a detected secret cannot
  reach the SSM parameter that Terraform reads. An empty Goss suite is
  treated as a failure, not a pass.
