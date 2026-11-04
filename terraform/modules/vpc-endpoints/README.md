# vpc-endpoints

Interface and gateway VPC endpoints for access nodes in fully private
subnets with no NAT gateway.

## Which endpoints, and why only these

Each interface endpoint costs roughly **$0.01/hour per AZ** (~$7.30 per
month per AZ), so a module that creates endpoints nobody uses is a
recurring bill with no owner. Defaults follow current AWS documentation
for Session Manager and nothing more.

| Endpoint | Type | Default | Why |
|---|---|---|---|
| `ssm` | Interface | **on** | The Systems Manager service endpoint. The agent calls `ssm:UpdateInstanceInformation` to register, and an unregistered node is not a valid session target. |
| `ssmmessages` | Interface | **on** | Session Manager's data channel. Without it, sessions cannot be established at all. |
| `s3` | Gateway | **on** | SSM Agent updates itself from S3. Gateway endpoints are **free**, so there is no cost reason to disable it. |
| `kms` | Interface | **on** | Needed when session data is KMS-encrypted — the node calls `kms:GenerateDataKey`. |
| `logs` | Interface | **on** | Needed to ship session logs and CloudWatch Agent output from a subnet with no NAT. |
| `ec2messages` | Interface | **off** | Legacy. From SSM Agent **3.3.40.0** onward AWS uses `ssmmessages` whenever available. Enable only if pinned to an older agent. |
| `ec2` | Interface | **off** | AWS documents this as required only for VSS-enabled snapshots, which this kit does not use. |

**Deliberately not created:** `sts`, `ecr`, `secretsmanager`,
`monitoring`. Nothing in the access path calls them. Add them in your
own configuration if your workloads need them.

## Cost, honestly

Four interface endpoints across two AZs is roughly **$58/month**. A
single NAT gateway is **~$33/month plus data processing**, and most
teams end up running one per AZ (~$66) for availability.

So the no-NAT configuration is usually both **cheaper and more
contained**: there is no route to the internet for an attacker to
exfiltrate over. `terraform output monthly_cost_estimate_usd` gives the
figure for your deployment.

The trade-off: with no NAT there is no fallback. Anything the node needs
must have an endpoint, so a missing one is an outage rather than a slow
path. That is why this module has preconditions instead of silent
defaults.

## Usage

```hcl
module "vpc_endpoints" {
  source = "./terraform/modules/vpc-endpoints"

  name   = "bfa"
  vpc_id = aws_vpc.this.id

  # One endpoint ENI per AZ that runs access nodes. A node in an AZ
  # with no endpoint ENI cannot reach the service.
  subnet_ids      = aws_subnet.private[*].id
  route_table_ids = [aws_route_table.private.id]

  # Reference the node's security group rather than a CIDR: tighter,
  # and it survives re-addressing the VPC.
  access_node_security_group_ids = [module.access_node.security_group_id]
}
```

## Things that silently break this

Collected here because each one produces an unreachable node with an
unhelpful error:

- **`enable_dns_support` and `enable_dns_hostnames` must both be true
  on the VPC.** Otherwise private DNS cannot resolve the endpoints and
  the agent never arrives. The module cannot set these — they belong to
  the VPC — so check them.
- **`private_dns_enabled` must stay true.** With it false, SSM Agent
  resolves the *public* service hostname, so the endpoints are paid for
  and unused. The module has a precondition rather than letting you
  disable it quietly.
- **The endpoint security group must allow inbound 443 from the
  node.** AWS documents this explicitly. Note the inbound rule is on
  the *endpoint*, not on the access node — the node still has none.
- **A gateway endpoint needs route table associations.** It works by
  injecting routes, so one not associated with your subnets' route
  tables does nothing. The module requires `route_table_ids`.
- **One endpoint ENI per AZ you run nodes in.** Pass every private
  subnet, not just one.
- **A custom DNS server needs a conditional forwarder** for
  `amazonaws.com` to the VPC's Amazon DNS server.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | string | `"bfa"` | Name prefix. |
| `vpc_id` | string | — | VPC to create endpoints in. |
| `subnet_ids` | list(string) | — | One per AZ running access nodes. |
| `route_table_ids` | list(string) | `[]` | Required when `enable_s3_endpoint`. |
| `access_node_security_group_ids` | list(string) | `[]` | Preferred over a CIDR. |
| `vpc_cidr_block` | string | `""` | Fallback when no SG is given. |
| `enable_ssm_endpoint` | bool | `true` | Required. |
| `enable_ssmmessages_endpoint` | bool | `true` | Required. |
| `enable_s3_endpoint` | bool | `true` | Free; agent self-updates. |
| `enable_ec2messages_endpoint` | bool | `false` | Legacy. |
| `enable_kms_endpoint` | bool | `true` | For KMS-encrypted sessions. |
| `enable_logs_endpoint` | bool | `true` | For session and OS logs. |
| `enable_ec2_endpoint` | bool | `false` | VSS snapshots only. |
| `private_dns_enabled` | bool | `true` | Keep true. |
| `endpoint_policy_json` | string | `""` | Optional endpoint policy. |
| `create_security_group` | bool | `true` | |
| `endpoint_security_group_ids` | list(string) | `[]` | |
| `tags` | map(string) | `{}` | |

## Outputs

| Name | Description |
|---|---|
| `interface_endpoint_ids` | Service name to endpoint ID. |
| `interface_endpoint_dns_entries` | For diagnosing resolution problems. |
| `s3_endpoint_id` | Gateway endpoint ID, or empty. |
| `s3_endpoint_prefix_list_id` | For an egress rule if you narrow `egress_cidr_blocks`. |
| `security_group_id` | Endpoint security group, or empty. |
| `enabled_endpoints` | What was created, for review. |
| `monthly_cost_estimate_usd` | Rough cost, to compare against a NAT gateway. |

## Preconditions

The plan fails, with an explanation, when a messages endpoint is
missing, `ssm` is disabled while `ssmmessages` is on, the S3 endpoint
has no route tables, the security group configuration is incomplete, or
`private_dns_enabled` is false.
