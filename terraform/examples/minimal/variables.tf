variable "region" {
  type        = string
  description = "AWS region."
  default     = "us-east-1"
}

variable "name" {
  type        = string
  description = "Name prefix for everything this example creates."
  default     = "bfa-minimal"
}

variable "environment" {
  type        = string
  description = "Environment tag value."
  default     = "example"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR for the example VPC."
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "instance_type" {
  type        = string
  description = "Access node instance type. Must match the AMI architecture."
  default     = "t3.small"
}

variable "trusted_principal_arns" {
  type        = list(string)
  description = "IAM principals allowed to assume the platform team's access role, e.g. [\"arn:aws:iam::111122223333:root\"] or a specific role ARN. Required: a role with an empty trust policy cannot be assumed by anyone."

  validation {
    condition     = length(var.trusted_principal_arns) > 0
    error_message = "trusted_principal_arns must contain at least one principal ARN, or nobody will be able to assume the access role."
  }
}
