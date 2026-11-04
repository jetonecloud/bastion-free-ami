# Build matrix: x86_64, from the published hardened-al2023 AMI.
#
#   packer build -var-file=x86_64.pkrvars.hcl .

arch          = "x86_64"
instance_type = "t3.small"
