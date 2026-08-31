variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "ap-south-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use."
  type        = string
  default     = "pro"
}

variable "project" {
  description = "Project tag / naming prefix component, passed through to every module."
  type        = string
  default     = "eks-platform"
}

variable "environment" {
  description = "Environment tag / naming prefix component. This is the nightly-teardown environment - see CLAUDE.md §6."
  type        = string
  default     = "staging"
}

variable "kubernetes_version" {
  description = "EKS version, passed to the eks module."
  type        = string
  default     = "1.35"
}

variable "engine_version" {
  description = "PostgreSQL minor version, passed to the rds module."
  type        = string
  default     = "16.15"
}

variable "instance_class" {
  description = "RDS instance class, passed to the rds module."
  type        = string
  default     = "db.t4g.micro"
}
