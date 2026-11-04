variable "enabled" {
  type        = bool
  description = "Create the EC2 Instance Connect Endpoint. OFF by default: EICE requires an inbound SSH rule on the TARGET host's security group, which reintroduces exactly what this kit removes. Read the module README before enabling."
  default     = false
}

variable "name" {
  type        = string
  description = "Name prefix for resources created by this module."
  default     = "bfa-eice"
}

variable "i_understand_this_reintroduces_ssh" {
  type        = bool
  description = "Second key required alongside enabled = true. EICE works by opening a TCP tunnel to port 22 (or another port) on a target host, so that host must accept inbound SSH from the endpoint. This is narrower than a public bastion -- the source is an AWS-managed endpoint, not the internet -- but it is not nothing, and it should be a deliberate decision rather than a default somebody inherited."
  default     = false
}

variable "vpc_id" {
  type        = string
  description = "VPC to create the endpoint in. Only used for the endpoint security group."
  default     = ""
}

variable "subnet_id" {
  type        = string
  description = "Subnet for the endpoint. A single subnet is correct: the endpoint reaches any instance in the VPC, so a second one buys nothing but cost."
  default     = ""
}

variable "preserve_client_ip" {
  type        = bool
  description = "Preserve the client's IP as the connection source. Defaults to false here (AWS defaults to true) so that target security groups can reference the endpoint's security group rather than an unpredictable client IP range -- which is both simpler and tighter. Set true only if you need the client IP in target-side logs."
  default     = false
}

variable "create_security_group" {
  type        = bool
  description = "Create a security group for the endpoint. Referencing this group in the target's inbound rule is how you keep that rule narrow."
  default     = true
}

variable "security_group_ids" {
  type        = list(string)
  description = "Existing security groups for the endpoint, used when create_security_group is false."
  default     = []
}

variable "target_cidr_blocks" {
  type        = list(string)
  description = "CIDRs the endpoint may reach on the allowed ports. Narrow this to the subnets holding hosts that genuinely need SSH -- not the whole VPC."
  default     = []

  validation {
    condition     = alltrue([for c in var.target_cidr_blocks : can(cidrnetmask(c))])
    error_message = "target_cidr_blocks must all be valid IPv4 CIDR blocks."
  }
}

variable "allowed_ports" {
  type        = list(number)
  description = "Ports the endpoint may tunnel to. Defaults to SSH only. Add 3389 for Windows RDP."
  default     = [22]

  validation {
    condition     = length(var.allowed_ports) > 0
    error_message = "allowed_ports must contain at least one port."
  }

  validation {
    condition     = alltrue([for p in var.allowed_ports : p > 0 && p < 65536])
    error_message = "Every allowed_ports entry must be between 1 and 65535."
  }
}

#
# IAM. Unlike Session Manager port forwarding, EICE DOES support
# conditioning on destination port and private IP, so these map
# one-to-one onto real condition keys.
#
variable "create_iam_policy" {
  type        = bool
  description = "Emit an IAM policy for ec2-instance-connect:OpenTunnel scoped by port, destination IP, and tunnel duration."
  default     = true
}

variable "iam_allowed_remote_ports" {
  type        = list(number)
  description = "Ports the policy permits via the ec2-instance-connect:remotePort condition key. Unlike Session Manager port forwarding, this really is enforced by IAM."
  default     = [22]

  validation {
    condition     = alltrue([for p in var.iam_allowed_remote_ports : p > 0 && p < 65536])
    error_message = "Every iam_allowed_remote_ports entry must be between 1 and 65535."
  }
}

variable "iam_allowed_private_ip_cidrs" {
  type        = list(string)
  description = "Destination private IP CIDRs the policy permits, via the ec2-instance-connect:privateIpAddress condition key. Empty omits the condition, which permits any instance in the VPC."
  default     = []

  validation {
    condition     = alltrue([for c in var.iam_allowed_private_ip_cidrs : can(cidrnetmask(c))])
    error_message = "iam_allowed_private_ip_cidrs must all be valid IPv4 CIDR blocks."
  }
}

variable "iam_max_tunnel_duration_seconds" {
  type        = number
  description = "Upper bound on tunnel duration, via ec2-instance-connect:maxTunnelDuration. Callers must then pass --max-tunnel-duration. Set 0 to omit the condition."
  default     = 3600

  validation {
    condition     = var.iam_max_tunnel_duration_seconds == 0 || (var.iam_max_tunnel_duration_seconds >= 1 && var.iam_max_tunnel_duration_seconds <= 3600)
    error_message = "iam_max_tunnel_duration_seconds must be 0 (omit) or between 1 and 3600."
  }
}

variable "iam_target_tag_key" {
  type        = string
  description = "Tag key restricting which instances may be tunnelled to, via aws:ResourceTag. Empty omits the condition."
  default     = ""
}

variable "iam_target_tag_value" {
  type        = string
  description = "Tag value paired with iam_target_tag_key."
  default     = ""
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource this module creates."
  default     = {}
}
