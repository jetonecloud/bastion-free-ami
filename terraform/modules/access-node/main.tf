data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  security_group_ids = (
    var.create_security_group
    ? [aws_security_group.access_node[0].id]
    : var.security_group_ids
  )

  tags = merge(
    {
      Project   = "bastion-free-ami"
      Module    = "access-node"
      ManagedBy = "terraform"
    },
    var.tags
  )

  # The access tag is load-bearing: access-iam's ssm:resourceTag
  # condition matches it to decide who may start a session here. It is
  # kept separate from local.tags so it is obvious that removing it
  # revokes access rather than just untidying a console view.
  instance_tags = merge(
    local.tags,
    {
      Name                   = var.name
      (var.access_tag_key)   = var.access_tag_value
      BastionFreeAmiNodeRole = "access-node"
    }
  )
}

resource "terraform_data" "preconditions" {
  input = var.name

  lifecycle {
    precondition {
      condition     = var.create_security_group || length(var.security_group_ids) > 0
      error_message = "Set create_security_group = true, or pass security_group_ids. An access node with no security group would fall back to the VPC default group, which commonly has rules you did not intend."
    }

    precondition {
      condition     = !(var.create_security_group && length(var.security_group_ids) > 0)
      error_message = "create_security_group = true and security_group_ids are mutually exclusive. Pick one, so it is unambiguous which group governs this node."
    }

    precondition {
      condition     = var.max_size >= var.desired_capacity && var.desired_capacity >= var.min_size
      error_message = "Capacity must satisfy min_size <= desired_capacity <= max_size."
    }

    # A 100% min-healthy refresh has to launch a replacement before
    # terminating anything, which it cannot do at max capacity. Caught
    # here rather than as a stuck refresh discovered during an AMI
    # rollout.
    precondition {
      condition = (
        !var.enable_instance_refresh ||
        var.instance_refresh_min_healthy_percentage < 100 ||
        var.max_size > var.desired_capacity
      )
      error_message = "instance_refresh_min_healthy_percentage = 100 requires max_size > desired_capacity, otherwise the refresh cannot launch a replacement before terminating a node and will stall. Either raise max_size or lower the percentage."
    }

    precondition {
      condition     = !var.enable_schedule || var.schedule_scale_down_desired_capacity < var.desired_capacity
      error_message = "enable_schedule is pointless unless schedule_scale_down_desired_capacity is below desired_capacity."
    }
  }
}

# ---------------------------------------------------------------------
# Launch template
# ---------------------------------------------------------------------
resource "aws_launch_template" "access_node" {
  name_prefix            = "${var.name}-"
  description            = "bastion-free-ami access node: no public IP, no key pair, IMDSv2 required"
  image_id               = var.ami_id
  instance_type          = var.instance_type
  update_default_version = true

  iam_instance_profile {
    name = aws_iam_instance_profile.access_node.name
  }

  # --- Not a variable: no key pair. There is no key_name argument here
  # and no variable that could set one. sshd is masked on the AMI, so a
  # key pair would be useless as well as contrary to the point. ---

  # --- Not a variable: IMDSv2 required, hop limit 1. Hop limit 1 stops
  # a container or proxied process on the node from reaching the
  # metadata service and borrowing this role, which matters on a host
  # where many people can get a shell. ---
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = var.root_volume_size_gb
      volume_type = "gp3"
      # Not a variable.
      encrypted             = true
      kms_key_id            = var.ebs_kms_key_id != "" ? var.ebs_kms_key_id : null
      delete_on_termination = true
    }
  }

  network_interfaces {
    # --- Not a variable: no public IP, ever. This is the single most
    # important line in the module. ---
    associate_public_ip_address = false
    security_groups             = local.security_group_ids
    delete_on_termination       = true
  }

  monitoring {
    enabled = var.enable_detailed_monitoring
  }

  # No user_data.
  #
  # The node is fully functional as baked: reachability depends only on
  # SSM Agent and the instance role, both present before boot. User data
  # that could fail would mean a node that launches but cannot be
  # reached, with no SSH to go and find out why. Self-healing must not
  # depend on a bootstrap script succeeding.

  tag_specifications {
    resource_type = "instance"
    tags          = local.instance_tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.instance_tags
  }

  tag_specifications {
    resource_type = "network-interface"
    tags          = local.instance_tags
  }

  tags = merge(local.tags, { Name = "${var.name}-lt" })

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------
# Auto Scaling Group
#
# An ASG rather than a standalone instance, because the access node is
# the thing you use to fix problems and so must not need a human to
# recover. EC2 health checks replace a failed node with no involvement
# from anyone, and crucially without anyone needing to log in.
# ---------------------------------------------------------------------
resource "aws_autoscaling_group" "access_node" {
  name_prefix = "${var.name}-"

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity

  # Multi-AZ when given multiple subnets: losing an AZ costs capacity,
  # not access.
  vpc_zone_identifier = var.subnet_ids

  launch_template {
    id      = aws_launch_template.access_node.id
    version = aws_launch_template.access_node.latest_version
  }

  # EC2 health checks: there is no load balancer in front of an access
  # node, so instance health is the only signal available.
  health_check_type         = "EC2"
  health_check_grace_period = var.health_check_grace_period

  # Replace the oldest node first, so a long-lived node that has drifted
  # or accumulated state is the one that goes.
  termination_policies = ["OldestInstance"]

  # Keep capacity balanced across AZs even after a zone recovers.
  capacity_rebalance = true

  # How an AMI update is deployed: change ami_id, apply, and the ASG
  # cycles nodes. Nobody logs in to upgrade anything.
  dynamic "instance_refresh" {
    for_each = var.enable_instance_refresh ? [1] : []

    content {
      strategy = "Rolling"

      preferences {
        min_healthy_percentage = var.instance_refresh_min_healthy_percentage
        instance_warmup        = var.instance_warmup_seconds
        # If the new AMI produces nodes that never reach a healthy
        # state, roll back rather than grinding the whole ASG down to
        # nothing reachable.
        auto_rollback = true
      }

      # `triggers` is deliberately not set. A change to the launch
      # template already triggers a refresh implicitly, and listing it
      # here as an "additional" trigger is rejected by the provider.
    }
  }

  dynamic "tag" {
    for_each = local.instance_tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true

    # desired_capacity is ignored after creation because two other
    # things legitimately change it at run time: the optional schedule,
    # and the emergency scale-up in this module's outputs. Without this,
    # the next `terraform apply` would undo an operator's 03:00
    # scale-up and take access away again.
    #
    # The trade-off: changing var.desired_capacity alone will not move a
    # running ASG. Use the scale-up command from the outputs, or taint
    # the ASG, when you need Terraform's value to take effect.
    ignore_changes = [desired_capacity]
  }
}

# ---------------------------------------------------------------------
# Optional scale-to-zero schedule.
#
# Off by default. This is a cost control, and it is also a way to lock
# your team out of the VPC at 19:00 on the evening something breaks. The
# scale-up command is in this module's outputs; it needs only
# autoscaling:SetDesiredCapacity, not SSH.
# ---------------------------------------------------------------------
resource "aws_autoscaling_schedule" "scale_down" {
  count = var.enable_schedule ? 1 : 0

  scheduled_action_name  = "${var.name}-scale-down"
  autoscaling_group_name = aws_autoscaling_group.access_node.name

  min_size         = var.schedule_scale_down_desired_capacity
  max_size         = var.max_size
  desired_capacity = var.schedule_scale_down_desired_capacity

  recurrence = var.schedule_scale_down_cron
  time_zone  = var.schedule_time_zone != "" ? var.schedule_time_zone : null
}

resource "aws_autoscaling_schedule" "scale_up" {
  count = var.enable_schedule ? 1 : 0

  scheduled_action_name  = "${var.name}-scale-up"
  autoscaling_group_name = aws_autoscaling_group.access_node.name

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity

  recurrence = var.schedule_scale_up_cron
  time_zone  = var.schedule_time_zone != "" ? var.schedule_time_zone : null
}
