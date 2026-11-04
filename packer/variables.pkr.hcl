## -----------------------------------------------------------------------
## bastion-free-ami: input variables.
##
## The source-AMI variables are what select between the two build modes
## described in docs/design.md ("Decision: how this builds on
## hardened-al2023"). Everything security-relevant that is NOT a variable
## -- IMDSv2 required, hop limit 1, encrypted root volume, no key pair --
## is hardcoded in sources.pkr.hcl on purpose, so it cannot be disabled
## by a stray var file.
## -----------------------------------------------------------------------

variable "aws_region" {
  type        = string
  description = "Region to run the build in and publish the AMI to."
  default     = "us-east-1"
}

variable "arch" {
  type        = string
  description = "Target architecture: x86_64 or arm64. Must match instance_type."
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.arch)
    error_message = "arch must be \"x86_64\" or \"arm64\"."
  }
}

variable "instance_type" {
  type        = string
  description = "Build instance type. Must match arch (t3.small for x86_64, t4g.small for arm64)."
  default     = "t3.small"
}

#
# Source AMI selection -- see docs/design.md for the two modes.
#
# Default (hardened-ami mode): the most recent hardened-al2023 AMI this
# account owns. al2023-base.pkrvars.hcl flips all three of these to build
# from the public Amazon Linux 2023 AMI instead.
#
variable "source_ami_name_filter" {
  type        = string
  description = "Name filter for the source AMI. Defaults to the hardened-al2023 published AMI; set to \"al2023-ami-2023.*\" to build from the public AL2023 base."
  default     = "hardened-al2023-*"
}

variable "source_ami_owners" {
  type        = list(string)
  description = "Account IDs (or \"self\"/\"amazon\") that must own the source AMI. Never leave this empty: an unowned AMI filter will happily match a stranger's image."
  default     = ["self"]

  validation {
    condition     = length(var.source_ami_owners) > 0
    error_message = "source_ami_owners must not be empty; an unowned source_ami_filter can match an untrusted AMI."
  }
}

variable "apply_upstream_hardening" {
  type        = bool
  description = "Run the hardened-al2023 roles (fetched from the pinned git tag in ansible/requirements.yml) before the access_node role. Leave false when the source AMI is already hardened."
  default     = false
}

variable "ami_name_prefix" {
  type        = string
  description = "Prefix for the resulting AMI name."
  default     = "bastion-free-ami"
}

variable "build_version" {
  type        = string
  description = "Version string recorded in the AMI name, tags, and manifest."
  default     = "0.0.0-dev"
}

variable "root_volume_size_gb" {
  type        = number
  description = "Root volume size. An access node stores nothing; the default only needs to hold the OS and logs."
  default     = 10

  validation {
    condition     = var.root_volume_size_gb >= 8
    error_message = "root_volume_size_gb must be at least 8 GiB to fit the AL2023 root filesystem."
  }
}

variable "root_volume_type" {
  type        = string
  description = "Root volume type."
  default     = "gp3"
}

variable "kms_key_id" {
  type        = string
  description = "Optional KMS key ID/ARN for root volume and snapshot encryption. Empty uses the account's default EBS key -- encryption itself is never optional."
  default     = ""
}

#
# Build-time network. Leave blank to use the account's default VPC. The
# build instance needs outbound HTTPS (to reach dnf repos and the AWS
# APIs); it needs no inbound rule beyond the SSH that Packer's own
# ephemeral key pair uses.
#
variable "vpc_id" {
  type        = string
  description = "VPC for the build instance. Empty uses the account default VPC."
  default     = ""
}

variable "subnet_id" {
  type        = string
  description = "Subnet for the build instance. Empty uses a default subnet."
  default     = ""
}

variable "security_group_ids" {
  type        = list(string)
  description = "Security groups for the build instance. Empty lets Packer create a temporary group scoped to its own public IP."
  default     = []
}

variable "associate_public_ip_address" {
  type        = bool
  description = "Give the *build* instance a public IP. This has no bearing on instances launched from the AMI, which never get one (enforced in terraform/modules/access-node). Set false when building in a private subnet with VPC endpoints or NAT."
  default     = true
}

variable "ssh_username" {
  type        = string
  description = "Build-time SSH user. Packer generates an ephemeral key pair for this user and discards it when the build ends; the access_node role removes any authorized_keys it leaves behind."
  default     = "ec2-user"
}

variable "ami_users" {
  type        = list(string)
  description = "Account IDs to share the resulting AMI with."
  default     = []
}

variable "ami_regions" {
  type        = list(string)
  description = "Additional regions to copy the AMI to. Each copy is encrypted."
  default     = []
}

variable "extra_tags" {
  type        = map(string)
  description = "Additional tags for the AMI, snapshot, and build instance."
  default     = {}
}

#
# Test and scan gates. Versions are pinned with checksums; see
# packer/scripts/install-goss.sh and install-trivy.sh.
#
variable "goss_version" {
  type        = string
  description = "Goss release to install on the build instance."
  default     = "0.4.10"
}

# Checksums below are the published values from each project's own
# release manifest (goss_<v>_SHA256SUMS and trivy_<v>_checksums.txt).
# install-goss.sh / install-trivy.sh verify the downloaded archive
# against these BEFORE it is unpacked or executed. If you bump a
# version, re-read the checksum from the release manifest -- do not
# compute it from a file you already downloaded over the network.
variable "goss_checksum_x86_64" {
  type        = string
  description = "SHA256 of goss_<version>_linux_x86_64.tar.gz."
  default     = "26e365428946294bcec0c61d867bb3c8349f39feb3d0e6f59084e98632785cc7"
}

variable "goss_checksum_arm64" {
  type        = string
  description = "SHA256 of goss_<version>_linux_arm64.tar.gz."
  default     = "90a59612b4d67d9f1a9038634c000790136bb82526a69de1e81ac075c2f6d2c6"
}

variable "trivy_version" {
  type        = string
  description = "Trivy release to install on the build instance."
  default     = "0.76.1"
}

variable "trivy_checksum_x86_64" {
  type        = string
  description = "SHA256 of trivy_<version>_Linux-64bit.tar.gz."
  default     = "c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0"
}

variable "trivy_checksum_arm64" {
  type        = string
  description = "SHA256 of trivy_<version>_Linux-ARM64.tar.gz."
  default     = "e174dff2a6dba5e3ae41f8d0537a6324405bd08132497340304c6b20e0f16a1f"
}

variable "trivy_severity" {
  type        = string
  description = "Severities Trivy reports."
  default     = "HIGH,CRITICAL"
}

variable "trivy_fail_on_critical" {
  type        = bool
  description = "Fail the Packer build on a CRITICAL finding. Default false because OS package CVEs can lag upstream by a day or two; the CI pipeline parses the report and blocks the publish job instead."
  default     = false
}
