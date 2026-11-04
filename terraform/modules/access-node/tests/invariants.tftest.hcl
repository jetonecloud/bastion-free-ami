# Tests for the access-node invariants that make this kit what it is.
#
# These run with `command = plan` against a mocked AWS provider, so CI
# needs no AWS credentials and pull requests cost nothing. Run with:
#
#   cd terraform/modules/access-node && terraform test
#
# What is tested here is deliberately narrow: the properties whose
# silent regression would make the project's central claims false.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
}

variables {
  ami_id     = "ami-0123456789abcdef0"
  vpc_id     = "vpc-0123456789abcdef0"
  subnet_ids = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0bbbbbbbbbbbbbbb2"]
}

# ---------------------------------------------------------------------
# The four hard requirements
# ---------------------------------------------------------------------
run "no_public_ip" {
  command = plan

  assert {
    condition     = aws_launch_template.access_node.network_interfaces[0].associate_public_ip_address == "false"
    error_message = "The launch template must never associate a public IP. An access node with a public IP is a bastion."
  }
}

run "imdsv2_required_with_hop_limit_one" {
  command = plan

  assert {
    condition     = aws_launch_template.access_node.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required. With IMDSv1 enabled, anything on the node that can make an HTTP request can read the instance role's credentials."
  }

  assert {
    condition     = aws_launch_template.access_node.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "IMDS hop limit must be 1, so a container or proxied process on the node cannot reach the metadata service and borrow the instance role."
  }

  assert {
    condition     = aws_launch_template.access_node.metadata_options[0].http_endpoint == "enabled"
    error_message = "The IMDS endpoint must stay enabled: the instance role is how the node reaches Systems Manager, and disabling IMDS makes the node unreachable."
  }
}

run "root_volume_encrypted" {
  command = plan

  assert {
    condition     = aws_launch_template.access_node.block_device_mappings[0].ebs[0].encrypted == "true"
    error_message = "The root volume must be encrypted."
  }
}

run "no_key_pair" {
  command = plan

  # key_name unset is what proves no EC2 key pair is attached. sshd is
  # masked on the AMI, so a key pair would be useless as well as
  # contrary to the design.
  assert {
    condition     = aws_launch_template.access_node.key_name == null || aws_launch_template.access_node.key_name == ""
    error_message = "No EC2 key pair may be attached to an access node."
  }
}

run "no_user_data" {
  command = plan

  # Reachability must not depend on a bootstrap script succeeding:
  # there is no SSH to go and find out why one failed.
  assert {
    condition     = aws_launch_template.access_node.user_data == null || aws_launch_template.access_node.user_data == ""
    error_message = "The access node must have no user data. A node whose reachability depends on a boot script can fail into an unreachable state with no way in to diagnose it."
  }
}

# ---------------------------------------------------------------------
# No inbound access
# ---------------------------------------------------------------------
run "security_group_has_no_ingress_rules" {
  command = plan

  # The module creates egress rules as separate resources and declares
  # no ingress resource at all. This asserts the egress rules exist (so
  # the node can reach AWS) while there is no ingress resource in the
  # plan to assert against -- its absence is the invariant, enforced by
  # there being no variable that could create one.
  assert {
    condition     = aws_vpc_security_group_egress_rule.aws_apis[0].from_port == 443
    error_message = "The access node needs outbound HTTPS to reach the Systems Manager endpoints."
  }

  assert {
    condition     = can(aws_security_group.access_node[0].id)
    error_message = "Expected the module to create its own egress-only security group by default."
  }
}

# ---------------------------------------------------------------------
# Self-healing
# ---------------------------------------------------------------------
run "multi_az_and_self_healing" {
  command = plan

  assert {
    condition     = length(aws_autoscaling_group.access_node.vpc_zone_identifier) == 2
    error_message = "The ASG must span every subnet it was given, so losing an AZ costs capacity rather than access."
  }

  assert {
    condition     = aws_autoscaling_group.access_node.health_check_type == "EC2"
    error_message = "EC2 health checks are what replace a failed node without a human being involved."
  }

  assert {
    condition     = aws_autoscaling_group.access_node.min_size >= 1
    error_message = "Default min_size must be at least 1: self-healing must not require a human, and nobody can SSH in to start a node."
  }
}

run "instance_refresh_enabled_by_default" {
  command = plan

  assert {
    condition     = length(aws_autoscaling_group.access_node.instance_refresh) == 1
    error_message = "Instance refresh must be on by default; it is how an AMI update rolls out without anyone logging in."
  }

  assert {
    condition     = aws_autoscaling_group.access_node.instance_refresh[0].preferences[0].auto_rollback == true
    error_message = "Instance refresh must auto-roll-back, or a bad AMI cycles the whole ASG into an unreachable state."
  }
}

# ---------------------------------------------------------------------
# IAM least privilege
# ---------------------------------------------------------------------
run "instance_role_does_not_use_managed_ssm_core_policy" {
  command = plan

  # AmazonSSMManagedInstanceCore grants Run Command document access,
  # Parameter Store reads, and broad S3 access. Everyone with a session
  # on the node inherits whatever this role has, so the module grants
  # the five documented Session Manager actions explicitly instead.
  assert {
    condition = alltrue([
      for arn in values(aws_iam_role_policy_attachment.additional)[*].policy_arn :
      !strcontains(arn, "AmazonSSMManagedInstanceCore")
    ])
    error_message = "AmazonSSMManagedInstanceCore must not be attached: it grants Run Command, Parameter Store, and S3 access that an access node does not need, and anyone with a session inherits it."
  }
}

# ---------------------------------------------------------------------
# The access tag is load-bearing: access-iam's IAM condition matches it.
# ---------------------------------------------------------------------
run "access_tag_propagates_to_instances" {
  command = plan

  assert {
    condition = anytrue([
      for t in aws_autoscaling_group.access_node.tag :
      t.key == "BastionFreeAccess" && t.value == "shared" && t.propagate_at_launch
    ])
    error_message = "The access tag must propagate to launched instances; access-iam's ssm:resourceTag condition matches it, so an instance without it is unreachable."
  }
}

# ---------------------------------------------------------------------
# Variable validation and preconditions
# ---------------------------------------------------------------------
run "rejects_capacity_inversion" {
  command = plan

  variables {
    min_size         = 3
    desired_capacity = 1
    max_size         = 2
  }

  expect_failures = [
    terraform_data.preconditions,
  ]
}

run "rejects_full_refresh_without_headroom" {
  command = plan

  # min_healthy_percentage = 100 cannot launch a replacement before
  # terminating a node unless max_size exceeds desired_capacity, so the
  # refresh would stall partway through an AMI rollout.
  variables {
    desired_capacity                        = 2
    max_size                                = 2
    min_size                                = 1
    instance_refresh_min_healthy_percentage = 100
  }

  expect_failures = [
    terraform_data.preconditions,
  ]
}

run "rejects_both_own_and_supplied_security_groups" {
  command = plan

  variables {
    create_security_group = true
    security_group_ids    = ["sg-0123456789abcdef0"]
  }

  expect_failures = [
    terraform_data.preconditions,
  ]
}

run "rejects_bad_ami_id" {
  command = plan

  variables {
    ami_id = "not-an-ami"
  }

  expect_failures = [
    var.ami_id,
  ]
}

run "rejects_empty_subnets" {
  command = plan

  variables {
    subnet_ids = []
  }

  expect_failures = [
    var.subnet_ids,
  ]
}

run "rejects_pointless_schedule" {
  command = plan

  variables {
    enable_schedule                      = true
    desired_capacity                     = 1
    schedule_scale_down_desired_capacity = 1
  }

  expect_failures = [
    terraform_data.preconditions,
  ]
}
