# Build matrix: arm64 (Graviton), from the published hardened-al2023 AMI.
#
#   packer build -var-file=arm64.pkrvars.hcl .
#
# NOTE: this requires an arm64 hardened-al2023 AMI to exist in the account.
# hardened-al2023's own template is single-arch and most accounts have only
# published x86_64. If `packer build` cannot find a source AMI, either
# publish an arm64 hardened-al2023 first, or build arm64 from the public
# base with -var-file=al2023-base.pkrvars.hcl. See docs/design.md.

arch          = "arm64"
instance_type = "t4g.small"
