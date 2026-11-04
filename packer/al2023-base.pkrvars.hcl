# Build mode: from the public Amazon Linux 2023 AMI, applying the
# hardened-al2023 roles from the pinned git tag in
# ansible/requirements.yml before the access_node role.
#
# Use this when you do not publish hardened-al2023 yourself, or to build
# arm64 without first publishing an arm64 hardened base. Combine with an
# arch var file:
#
#   packer build -var-file=al2023-base.pkrvars.hcl \
#                -var-file=arm64.pkrvars.hcl .
#
# The build takes noticeably longer in this mode because it applies the
# full CIS-aligned baseline rather than inheriting it.

source_ami_name_filter   = "al2023-ami-2023.*"
source_ami_owners        = ["amazon"]
apply_upstream_hardening = true
