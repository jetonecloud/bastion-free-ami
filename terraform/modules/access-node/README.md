# access-node

Launch template and Auto Scaling Group for private access nodes: no
public IP, no inbound rules, no SSH keys, no static credentials.

## What is not configurable, on purpose

Four properties are hardcoded with no variable able to change them,
because they are the project's central claims rather than preferences:

| Property | Where |
|---|---|
| `associate_public_ip_address = false` | `aws_launch_template.network_interfaces` |
| IMDSv2 required, `http_put_response_hop_limit = 1` | `aws_launch_template.metadata_options` |
| Root volume `encrypted = true` | `aws_launch_template.block_device_mappings` |
| No `key_name` — the argument is absent | `aws_launch_template` |

There is also **no ingress block and no variable that could add one**.
Session Manager needs no inbound rule: SSM Agent dials out to the
`ssmmessages` endpoint and holds the channel open. If you need inbound
SSH on some *other* host, see `terraform/modules/eice`, which is
explicit about what that costs.

`terraform test` asserts all of these, so a future edit that removes one
fails CI.

## Usage

```hcl
data "aws_ssm_parameter" "access_node_ami" {
  name = "/bastion-free-ami/${var.region}/latest"
}

module "access_node" {
  source = "./terraform/modules/access-node"

  name   = "bfa-access-node"
  vpc_id = aws_vpc.this.id

  ami_id        = data.aws_ssm_parameter.access_node_ami.value
  instance_type = "t3.small"

  # Private subnets, one per AZ.
  subnet_ids = aws_subnet.private[*].id

  min_size         = 1
  max_size         = 3
  desired_capacity = 2

  # Narrow once you know what you forward to.
  egress_cidr_blocks = [aws_vpc.this.cidr_block]

  session_log_group_name = module.session_logging.cloudwatch_log_group_name
  session_kms_key_arn    = module.session_logging.kms_key_arn
}
```

## Self-healing without SSH

The access node is the thing you use to fix problems, so it must not
need itself to recover:

- **An ASG, not an instance.** EC2 health checks replace a failed node
  with no human involvement and no login.
- **Multi-AZ** when given multiple subnets. Losing an AZ costs
  capacity, not access.
- **Instance refresh with `auto_rollback`.** An AMI update is deployed
  by changing `ami_id` and applying; the ASG cycles nodes. A bad AMI
  rolls back rather than cycling the fleet into an unreachable state.
- **No user data.** The node is functional as baked, so reachability
  cannot depend on a boot script succeeding — there would be no SSH to
  go and find out why one failed.
- **`emergency_scale_up_command`** is an output, correct for this
  deployment, needing only `autoscaling:SetDesiredCapacity`. Put it in
  your incident runbook.

### `desired_capacity` is ignored after creation

Two things legitimately change it at run time: the optional schedule,
and an operator's emergency scale-up. Without `ignore_changes`, the
next `terraform apply` would undo a 03:00 scale-up and remove access
again.

The trade-off: changing `var.desired_capacity` alone will not move a
running ASG. Use the scale-up command, or taint the ASG.

## The access tag is load-bearing

`access_tag_key` / `access_tag_value` are propagated to instances and
matched by `access-iam`'s `ssm:resourceTag` condition on
`ssm:StartSession`. **An instance without the tag is unreachable.**

Tags come from the launch template, so a tag change only affects *new*
instances — start an instance refresh after changing one.

Pass the outputs straight into `access-iam` so the two cannot drift:

```hcl
module "access_iam" {
  access_tag_key = module.access_node.access_tag_key
  teams = {
    platform = { access_tag_value = module.access_node.access_tag_value, ... }
  }
}
```

## The instance role

Everything this role can do, anyone with a shell on the node can do —
and the point of the node is that many people can. So it grants the five
Session Manager actions AWS documents as the minimum, plus session
logging scoped to one log group, one bucket prefix, and one KMS key.

**`AmazonSSMManagedInstanceCore` is deliberately not attached.** That
managed policy adds Run Command document access, Parameter Store reads,
and broad S3 access that an access node does not need.

Three statements use `Resource: "*"` unavoidably, each commented in
`iam.tf`: the `ssmmessages` channel actions have no ARN to name,
`ssm:UpdateInstanceInformation` writes the calling instance's own
record, and `logs:DescribeLogGroups` is a list operation with no
condition key.

If you add `additional_policy_arns`, you grant it to everyone who can
open a session.

## The scale-to-zero schedule

Off by default. It is a cost control, and it is also a way to lock your
team out of the VPC at 19:00 on the evening something breaks.

When enabled, `schedule_summary` says so in the outputs, so an on-call
engineer finds out before they are paged rather than after.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | `"bfa-access-node"` | Name prefix. |
| `ami_id` | string | — | AMI from `packer/`. Read it from SSM. |
| `instance_type` | string | `"t3.small"` | Must match the AMI architecture. |
| `subnet_ids` | list(string) | — | **Private** subnets, one per AZ. |
| `vpc_id` | string | — | VPC for the security group. |
| `create_security_group` | bool | `true` | Create the egress-only group. |
| `security_group_ids` | list(string) | `[]` | Existing groups. Must have no inbound rules. |
| `egress_cidr_blocks` | list(string) | `["0.0.0.0/0"]` | Where the node may connect. Narrow to your VPC CIDR. |
| `min_size` | number | `1` | Keep ≥ 1 unless using the schedule. |
| `max_size` | number | `2` | Must exceed `desired_capacity` for a 100%-healthy refresh. |
| `desired_capacity` | number | `1` | Ignored after creation; see above. |
| `health_check_grace_period` | number | `300` | Must cover boot plus SSM registration. |
| `root_volume_size_gb` | number | `10` | ≥ 8. |
| `ebs_kms_key_id` | string | `""` | Empty uses the default EBS key. Encryption is not optional. |
| `enable_detailed_monitoring` | bool | `false` | 1-minute metrics. |
| `enable_instance_refresh` | bool | `true` | How AMI updates roll out. |
| `instance_refresh_min_healthy_percentage` | number | `100` | 100 needs `max_size > desired_capacity`. |
| `instance_warmup_seconds` | number | `180` | Must cover SSM registration. |
| `enable_schedule` | bool | `false` | Scale to zero out of hours. |
| `schedule_scale_down_cron` | string | `"0 19 * * MON-FRI"` | |
| `schedule_scale_up_cron` | string | `"0 7 * * MON-FRI"` | |
| `schedule_scale_down_desired_capacity` | number | `0` | |
| `schedule_time_zone` | string | `""` | IANA zone; empty means UTC. |
| `session_log_group_name` | string | `""` | From `session-logging`. |
| `session_log_bucket_arn` | string | `""` | From `session-logging`. |
| `session_log_bucket_prefix` | string | `"sessions/"` | |
| `session_kms_key_arn` | string | `""` | From `session-logging`. |
| `attach_cloudwatch_agent_policy` | bool | `true` | For OS logs and the disk alarm. |
| `additional_policy_arns` | list(string) | `[]` | Granted to everyone with a session. |
| `access_tag_key` | string | `"BastionFreeAccess"` | Matched by `access-iam`. |
| `access_tag_value` | string | `"shared"` | Use distinct values per pool. |
| `tags` | map(string) | `{}` | |

## Outputs

| Name | Description |
|---|---|
| `autoscaling_group_name` / `_arn` | The ASG. |
| `launch_template_id` / `_latest_version` | The launch template. |
| `security_group_id` | Egress-only group, or empty. |
| `iam_role_arn` / `_name` | Instance role. |
| `iam_instance_profile_name` | Needed by `tests/smoke-test.sh`. |
| `access_tag_key` / `access_tag_value` | Pass straight into `access-iam`. |
| `node_filter` | `KEY=VALUE` for `scripts/connect --tag`. |
| `find_node_command` | Read-only command listing healthy nodes. |
| `emergency_scale_up_command` | Restore capacity without SSH. |
| `start_instance_refresh_command` | Trigger an AMI rollout by hand. |
| `schedule_enabled` / `schedule_summary` | Whether access disappears out of hours. |

## Preconditions

The plan fails, with an explanation, when capacity is inverted, both a
created and a supplied security group are given, a 100%-healthy refresh
has no headroom, or the schedule would be a no-op.
