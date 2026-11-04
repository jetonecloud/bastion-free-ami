terraform {
  # 1.7.0 for the `removed` block and modern variable validation. This
  # constraint is also satisfied by OpenTofu 1.7+, which this module is
  # tested against; nothing here uses a Terraform-only feature.
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.x for `data.aws_region.region` (the `name` attribute is
      # deprecated as of provider 6.0) and current KMS/S3 defaults.
      version = ">= 6.0.0, < 7.0.0"
    }
  }
}
