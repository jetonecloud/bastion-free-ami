## -----------------------------------------------------------------------
## bastion-free-ami: Packer and plugin version pins.
##
## Plugin versions are pinned with an upper bound: a major-version bump in
## the amazon plugin has changed source-block semantics before, and this
## template's security properties (IMDSv2, encrypted root, no key pair)
## live in that block.
## -----------------------------------------------------------------------

packer {
  required_version = ">= 1.10.0"

  required_plugins {
    amazon = {
      version = ">= 1.3.3, < 2.0.0"
      source  = "github.com/hashicorp/amazon"
    }
    ansible = {
      version = ">= 1.1.1, < 2.0.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}
