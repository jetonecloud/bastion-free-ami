variable "name" {
  type        = string
  description = "Name prefix for resources created by this module."
  default     = "bfa"
}

variable "vpc_id" {
  type        = string
  description = "VPC to create the endpoints in."

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id))
    error_message = "vpc_id must be a VPC ID (vpc-...)."
  }
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnets for the interface endpoints. Use one per AZ that runs access nodes: an interface endpoint is an ENI per subnet, and a node in an AZ with no endpoint ENI cannot reach the service."

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "subnet_ids must contain at least one subnet."
  }
}

variable "route_table_ids" {
  type        = list(string)
  description = "Route tables to associate the S3 gateway endpoint with. Required when enable_s3_endpoint is true; the endpoint works by adding routes, so a route table it is not attached to gets no access."
  default     = []
}

variable "access_node_security_group_ids" {
  type        = list(string)
  description = "Security groups of the access nodes. The endpoint security group allows HTTPS from these. Leave empty to allow from vpc_cidr_block instead."
  default     = []
}

variable "vpc_cidr_block" {
  type        = string
  description = "VPC CIDR allowed to reach the interface endpoints on 443, used when access_node_security_group_ids is empty. Prefer the security group reference: it stays correct when the VPC is re-addressed."
  default     = ""

  validation {
    condition     = var.vpc_cidr_block == "" || can(cidrnetmask(var.vpc_cidr_block))
    error_message = "vpc_cidr_block must be a valid IPv4 CIDR block, or empty."
  }
}

#
# Which endpoints. Defaults follow current AWS documentation for Session
# Manager and nothing more -- each interface endpoint is billed per AZ
# per hour, so an over-eager default here is a recurring bill.
#
variable "enable_ssm_endpoint" {
  type        = bool
  description = "com.amazonaws.<region>.ssm -- the Systems Manager service endpoint. Required."
  default     = true
}

variable "enable_ssmmessages_endpoint" {
  type        = bool
  description = "com.amazonaws.<region>.ssmmessages -- required for Session Manager's data channel. Without it, sessions cannot be established at all."
  default     = true
}

variable "enable_s3_endpoint" {
  type        = bool
  description = "com.amazonaws.<region>.s3 as a GATEWAY endpoint. SSM Agent updates itself from S3. Gateway endpoints are free, so there is no cost reason to turn this off."
  default     = true
}

variable "enable_ec2messages_endpoint" {
  type        = bool
  description = "com.amazonaws.<region>.ec2messages. OFF by default: from SSM Agent 3.3.40.0 onward AWS uses the ssmmessages endpoint whenever it is available, so this is legacy. Enable only if you are pinned to an older agent."
  default     = false
}

variable "enable_kms_endpoint" {
  type        = bool
  description = "com.amazonaws.<region>.kms. Needed when session data is KMS-encrypted, because the node calls kms:GenerateDataKey. Enable alongside session-logging's KMS key."
  default     = true
}

variable "enable_logs_endpoint" {
  type        = bool
  description = "com.amazonaws.<region>.logs. Needed to ship session logs and CloudWatch Agent output from a subnet with no NAT."
  default     = true
}

variable "enable_ec2_endpoint" {
  type        = bool
  description = "com.amazonaws.<region>.ec2. OFF by default: AWS documents this as required only for VSS-enabled snapshots, which this kit does not use."
  default     = false
}

variable "private_dns_enabled" {
  type        = bool
  description = "Resolve the service's public hostname to the endpoint's private IPs. Keep true: with it false, SSM Agent still resolves the public endpoint and the endpoints go unused."
  default     = true
}

variable "endpoint_policy_json" {
  type        = string
  description = "Optional policy restricting what can be done through the interface endpoints, e.g. limiting to this account's principals. Empty uses the AWS default of full access through the endpoint, with IAM still applying."
  default     = ""
}

variable "create_security_group" {
  type        = bool
  description = "Create the endpoint security group. Set false and pass endpoint_security_group_ids to manage it yourself."
  default     = true
}

variable "endpoint_security_group_ids" {
  type        = list(string)
  description = "Existing security groups for the interface endpoints, used when create_security_group is false. Must allow inbound 443 from the access nodes."
  default     = []
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource this module creates."
  default     = {}
}
