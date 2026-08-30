variable "project" {
  description = "Project tag / naming prefix component."
  type        = string
}

variable "environment" {
  description = "Environment tag / naming prefix component (e.g. staging)."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets, one per AZ (ALB + NAT)."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "Exactly 2 public subnet CIDRs are required - this module is built for the 2-AZ layout in CLAUDE.md §7."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the private subnets, one per AZ (nodes + RDS)."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) == 2
    error_message = "Exactly 2 private subnet CIDRs are required - this module is built for the 2-AZ layout in CLAUDE.md §7."
  }
}

variable "flow_log_retention_days" {
  description = "CloudWatch Logs retention for VPC Flow Logs."
  type        = number
  default     = 3
}

variable "public_subnet_tags" {
  description = "Extra tags merged onto every public subnet, in addition to the required kubernetes.io/role/elb tag. Use this to add the kubernetes.io/cluster/<name> discovery tag once the cluster name is known, without this module needing to know it."
  type        = map(string)
  default     = {}
}

variable "private_subnet_tags" {
  description = "Extra tags merged onto every private subnet, in addition to the required kubernetes.io/role/internal-elb tag. Use this to add the kubernetes.io/cluster/<name> discovery tag once the cluster name is known, without this module needing to know it."
  type        = map(string)
  default     = {}
}
