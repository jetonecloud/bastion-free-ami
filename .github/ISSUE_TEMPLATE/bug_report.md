---
name: Bug report
about: Something does not work as documented
title: ""
labels: bug
assignees: ""
---

## What happened

<!-- Include the actual error. If an AWS API call failed, the full
error message and the operation name. -->

## What you expected

## Which part

- [ ] AMI build (`packer/`, `ansible/`)
- [ ] Goss test or smoke test
- [ ] A Terraform module — which one:
- [ ] `scripts/connect`
- [ ] `scripts/verify`
- [ ] An access path (`docs/access-paths.md`) — which one:
- [ ] Documentation
- [ ] CI

## Reproduction

<!-- A minimal Terraform or Packer var diff is ideal. -->

## Environment

- Region:
- Architecture: `x86_64` / `arm64`
- Source mode: `hardened-ami` / `al2023-base`
- Terraform or OpenTofu version:
- AWS provider version:
- Packer version (if building):
- `session-manager-plugin --version` (if connecting):

## Checked already

- [ ] This is not one of the documented limitations in
      [`docs/threat-model.md`](../../docs/threat-model.md) — in
      particular, port-forwarding and SSH session **contents** are not
      logged by AWS, which is expected behaviour
- [ ] `scripts/verify` output included below, if relevant

<details>
<summary><code>scripts/verify</code> output</summary>

```
paste here
```

</details>
