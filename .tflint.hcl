plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.35.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

config {
  call_module_type = "local"
}

# Every variable and output in this repo carries a description, on
# purpose: the descriptions are where the AWS-specific caveats live
# (which endpoints are legacy, why a wildcard is unavoidable, what a
# setting costs). Enforced rather than encouraged.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_deprecated_interpolation" {
  enabled = true
}

# The examples intentionally pin the provider in their own
# required_providers block rather than inheriting, so each is runnable
# standalone.
rule "terraform_module_pinned_source" {
  enabled = true
}
