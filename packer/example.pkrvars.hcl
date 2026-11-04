# Copy to local.pkrvars.hcl and edit. local.pkrvars.hcl is gitignored.
#
#   cp example.pkrvars.hcl local.pkrvars.hcl
#   packer build -var-file=local.pkrvars.hcl -var-file=x86_64.pkrvars.hcl .

aws_region = "us-east-1"

# Leave both blank to use the account's default VPC and a default subnet.
vpc_id    = ""
subnet_id = ""

# Set false when building inside a private subnet that reaches the AWS
# APIs through a NAT gateway or VPC endpoints. The build instance's public
# IP has no bearing on instances launched from the finished AMI -- those
# never get one.
associate_public_ip_address = true

# Optional CMK for root volume + snapshot encryption. Encryption happens
# either way; this only chooses the key.
kms_key_id = ""

# Recorded in the AMI name and tags. CI derives this from the git tag.
build_version = "0.1.0-local"

extra_tags = {
  Owner = "platform-team"
}
