## What this changes

<!-- One or two sentences. The "why" matters more than the "what" here. -->

## Why

<!-- If this is an AWS behaviour change or a new control, link the AWS
documentation page. Several decisions in this repo exist because the
obvious assumption turned out to be wrong, so a link saves the reviewer
re-deriving it. -->

## Checklist

- [ ] No hard requirement weakened (no public IPs, no inbound rules, no
      SSH keys, no static credentials, IMDSv2 + hop limit 1, encrypted
      volumes, no secrets in the image)
- [ ] Any new `Resource: "*"` or broad action has a comment saying why
      it is unavoidable and what bounds it instead
- [ ] Any new `.trivyignore` entry or Checkov skip carries its reason
- [ ] Docs updated in this PR (module README, and `docs/design.md` if a
      decision changed, `docs/threat-model.md` if a limit was found)
- [ ] A test covers it (Goss check, `terraform test` assertion, or a
      script test)
- [ ] No compliance claim added anywhere ("supporting evidence", never
      "compliant" or "certified")

## What I tested

<!-- Be specific: region, architecture, whether you ran a full
`packer build`, whether you ran tests/smoke-test.sh. "make test and
make lint pass" is fine for a docs or Terraform-only change. -->

- [ ] `make lint`
- [ ] `make validate`
- [ ] `make test` (and `make test TF=tofu` if Terraform changed)
- [ ] `make test-scripts` (if `scripts/` changed)
- [ ] `packer build` (if `packer/` or `ansible/` changed) — region/arch:
- [ ] `tests/smoke-test.sh` (if the AMI changed)
