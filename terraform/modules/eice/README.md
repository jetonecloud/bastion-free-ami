# eice

EC2 Instance Connect Endpoint, for tools that genuinely require SSH.

**Off by default**, and enabling it takes two keys:

```hcl
enabled                            = true
i_understand_this_reintroduces_ssh = true
```

## Why the second key exists

EICE works by opening a TCP tunnel to port 22 on a target host. For
that to work, **the target's security group must allow inbound SSH from
the endpoint**.

That is an inbound rule, on port 22, on a host that the rest of this kit
guarantees has neither. It is narrower than a public bastion — the
source is an AWS-managed endpoint, not the internet — but it is a real
inbound path, and `scripts/verify` will report it as one. It should be a
deliberate decision, not a default somebody inherited.

## When it is justified

Exactly one situation: **a tool that must speak real SSH.** `rsync`,
`scp`, `ssh -D`, an IDE remote-development plugin, or an appliance that
only knows SSH.

Session Manager's `AWS-StartSSHSession` can also do this, but EICE does
it without an SSM Agent on the target — which is the case for
appliances and third-party AMIs.

If what you actually want is a database connection or an HTTP service,
you do **not** need this. Use port forwarding; see
`docs/access-paths.md`.

## It cannot target the access node

The access node's `sshd` is masked and its security group has no
inbound rules, so a tunnel to it connects to nothing.

This module is for **other hosts** in the VPC that genuinely require
SSH. Reaching the access node is what Session Manager is for.

## What it does better than Session Manager

IAM scoping, genuinely. `ec2-instance-connect:OpenTunnel` honours three
condition keys that Session Manager port forwarding has no equivalent
of:

| Condition key | What it restricts |
|---|---|
| `ec2-instance-connect:remotePort` | The destination port |
| `ec2-instance-connect:privateIpAddress` | The destination IP |
| `ec2-instance-connect:maxTunnelDuration` | How long the tunnel may stay open |

So unlike port forwarding — where IAM cannot see the host or port at
all, and allowlisting requires minting a document per target — you can
allowlist destination and port **in the policy itself**. The `iam_*`
variables map one-to-one onto those keys.

If you need SSH *and* tight IAM scoping, this is the better tool. That
is the honest case for it.

## Usage

```hcl
module "eice" {
  source = "./terraform/modules/eice"

  enabled                            = true
  i_understand_this_reintroduces_ssh = true

  name      = "bfa-eice"
  vpc_id    = aws_vpc.this.id
  subnet_id = aws_subnet.private[0].id

  # Narrow to the subnets holding hosts that actually need SSH --
  # not the whole VPC.
  target_cidr_blocks = ["10.30.5.0/24"]
  allowed_ports      = [22]

  # Real IAM enforcement.
  iam_allowed_remote_ports        = [22]
  iam_allowed_private_ip_cidrs    = ["10.30.5.0/24"]
  iam_max_tunnel_duration_seconds = 3600
  iam_target_tag_key              = "SshRequired"
  iam_target_tag_value            = "true"
}
```

### The inbound rule you must add yourself

This module **deliberately does not create it**. The rule belongs to the
target host's security group, which this module does not own, and a
module named `eice` should not quietly open port 22 on somebody else's
host.

```hcl
resource "aws_vpc_security_group_ingress_rule" "ssh_from_eice" {
  security_group_id = aws_security_group.legacy_appliance.id
  description       = "SSH from EC2 Instance Connect Endpoint"

  ip_protocol = "tcp"
  from_port   = 22
  to_port     = 22

  # Reference the endpoint's security group rather than a CIDR:
  # tighter, and it survives re-addressing.
  referenced_security_group_id = module.eice.security_group_id
}
```

`terraform output required_target_security_group_rule` prints this with
the right IDs filled in.

## `preserve_client_ip` defaults to false here

AWS defaults it to `true`. This module defaults it to `false` so target
security groups can reference the endpoint's security group instead of
an unpredictable client IP range — which is both simpler to write and
tighter than any CIDR you could guess.

Set it true only if you need the client IP in target-side logs.

## Connecting

```sh
# SSH through the endpoint
ssh -i key.pem ec2-user@i-0123456789abcdef0 \
  -o ProxyCommand='aws ec2-instance-connect open-tunnel --instance-id %h'

# A raw tunnel
aws ec2-instance-connect open-tunnel \
  --instance-id i-0123456789abcdef0 \
  --local-port 2222 \
  --remote-port 22 \
  --max-tunnel-duration 3600
```

If `iam_max_tunnel_duration_seconds` is set, callers **must** pass
`--max-tunnel-duration` or AWS returns `AccessDeniedException`. The
`connect_commands` output says so.

## Logging

Tunnel contents are **not captured**, the same gap as Session Manager
port forwarding. CloudTrail records the `OpenTunnel` call — principal,
instance, port, time — not what passed through the tunnel.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `enabled` | bool | `false` | Create the endpoint. |
| `i_understand_this_reintroduces_ssh` | bool | `false` | Second key required. |
| `name` | string | `"bfa-eice"` | Name prefix. |
| `vpc_id` | string | `""` | Required when creating a security group. |
| `subnet_id` | string | `""` | Required when enabled. One is enough. |
| `preserve_client_ip` | bool | `false` | See above. |
| `create_security_group` | bool | `true` | |
| `security_group_ids` | list(string) | `[]` | |
| `target_cidr_blocks` | list(string) | `[]` | Required; narrow it. |
| `allowed_ports` | list(number) | `[22]` | Add 3389 for RDP. |
| `create_iam_policy` | bool | `true` | |
| `iam_allowed_remote_ports` | list(number) | `[22]` | Real IAM enforcement. |
| `iam_allowed_private_ip_cidrs` | list(string) | `[]` | Empty permits any instance in the VPC. |
| `iam_max_tunnel_duration_seconds` | number | `3600` | 0 omits the condition. |
| `iam_target_tag_key` / `_value` | string | `""` | Optional tag scoping. |
| `tags` | map(string) | `{}` | |

## Outputs

| Name | Description |
|---|---|
| `enabled` | Whether it was actually created (both keys). |
| `endpoint_id` / `_arn` / `_dns_name` | The endpoint. |
| `security_group_id` | Reference this in the target's inbound rule. |
| `iam_policy_arn` | The `OpenTunnel` policy. |
| `required_target_security_group_rule` | The rule you must add, with IDs filled in. |
| `connect_commands` | Example commands. |
| `limitations` | What EICE does and does not give you, as data. |
