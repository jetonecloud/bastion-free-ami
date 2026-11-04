## -----------------------------------------------------------------------
## bastion-free-ami: build source.
##
## Four properties in this file are deliberately NOT variables, so that no
## var file, CI misconfiguration, or copy-paste can turn them off:
##
##   1. IMDSv2 required (http_tokens = "required")
##   2. IMDS hop limit 1
##   3. Encrypted root volume and encrypted snapshot
##   4. No EC2 key pair -- Packer generates an ephemeral ed25519 key per
##      build and discards it on exit
##
## Everything else is in variables.pkr.hcl.
## -----------------------------------------------------------------------

locals {
  build_timestamp = formatdate("YYYYMMDD-hhmmss", timestamp())
  ami_name        = "${var.ami_name_prefix}-${var.arch}-${var.build_version}-${local.build_timestamp}"

  # Per-arch download tokens for the pinned test/scan binaries. Resolved
  # once here so the provisioning scripts never branch on var.arch.
  goss_arch     = var.arch == "arm64" ? "arm64" : "x86_64"
  goss_checksum = var.arch == "arm64" ? var.goss_checksum_arm64 : var.goss_checksum_x86_64

  trivy_arch     = var.arch == "arm64" ? "Linux-ARM64" : "Linux-64bit"
  trivy_checksum = var.arch == "arm64" ? var.trivy_checksum_arm64 : var.trivy_checksum_x86_64

  common_tags = merge(
    {
      Name            = local.ami_name
      Project         = "bastion-free-ami"
      ManagedBy       = "packer"
      Architecture    = var.arch
      BuildVersion    = var.build_version
      BuiltAt         = local.build_timestamp
      UpstreamApplied = var.apply_upstream_hardening ? "hardened-al2023-roles" : "source-ami"
      AccessModel     = "ssm-session-manager-only"
    },
    var.extra_tags
  )
}

source "amazon-ebs" "access_node" {
  region        = var.aws_region
  instance_type = var.instance_type
  ssh_username  = var.ssh_username

  # Resolves the source AMI at build time rather than pinning a stale ID.
  # owners is validated non-empty in variables.pkr.hcl: an unowned filter
  # can match an AMI published by someone else entirely.
  source_ami_filter {
    owners      = var.source_ami_owners
    most_recent = true
    filters = {
      name                = var.source_ami_name_filter
      architecture        = var.arch
      virtualization-type = "hvm"
      root-device-type    = "ebs"
      state               = "available"
    }
  }

  ami_name        = local.ami_name
  ami_description = "Bastion-free access node (${var.arch}) -- Session Manager only, sshd masked, no inbound ports. Built ${local.build_timestamp}."

  vpc_id                      = var.vpc_id != "" ? var.vpc_id : null
  subnet_id                   = var.subnet_id != "" ? var.subnet_id : null
  security_group_ids          = length(var.security_group_ids) > 0 ? var.security_group_ids : null
  associate_public_ip_address = var.associate_public_ip_address

  ami_users   = var.ami_users
  ami_regions = var.ami_regions

  # --- Not a variable: no static SSH key is ever written to disk or
  # committed. Packer mints a throwaway key pair for this build only. The
  # access_node role removes the authorized_keys entry it leaves behind,
  # and sshd is masked regardless. ---
  temporary_key_pair_type = "ed25519"

  # --- Not a variable: IMDSv2 required, hop limit 1. Hop limit 1 means a
  # container or a proxied process on the node cannot reach the metadata
  # service and borrow the instance role. On an access node that every
  # engineer can get a shell on, that matters more than it does on a
  # single-tenant workload host. ---
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  # --- Not a variable: encrypted root volume. AL2023 publishes /dev/xvda
  # as the root device for both x86_64 and arm64. ---
  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = var.root_volume_size_gb
    volume_type           = var.root_volume_type
    delete_on_termination = true
    encrypted             = true
    kms_key_id            = var.kms_key_id != "" ? var.kms_key_id : null
  }

  # --- Not a variable: the resulting AMI's snapshot is encrypted too.
  # encrypt_boot covers the snapshot that the AMI registers, including
  # copies made into ami_regions. ---
  encrypt_boot = true
  kms_key_id   = var.kms_key_id != "" ? var.kms_key_id : null

  tags            = local.common_tags
  run_tags        = local.common_tags
  run_volume_tags = local.common_tags
  snapshot_tags   = local.common_tags

  shutdown_behavior = "terminate"
  communicator      = "ssh"
}
