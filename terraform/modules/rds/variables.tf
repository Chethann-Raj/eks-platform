variable "project" {
  description = "Project tag / naming prefix component."
  type        = string
}

variable "environment" {
  description = "Environment tag / naming prefix component (e.g. staging)."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID from the vpc module (needed for the DB security group)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs from the vpc module. The DB subnet group and the instance itself live here only."
  type        = list(string)
}

variable "node_security_group_id" {
  description = <<-EOT
    Security group ID that's allowed to reach Postgres on 5432. In practice
    this is the eks module's node_security_group_id output, which is EKS's
    auto-created cluster security group - also attached to control plane
    ENIs, not just worker nodes. See README for what that approximation
    means in practice.
  EOT
  type        = string
}

variable "engine_version" {
  description = "Pinned PostgreSQL minor version - queried via `aws rds describe-db-engine-versions`, not guessed. See README."
  type        = string
  default     = "16.15"
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_name" {
  description = "Name of the default database created on the instance."
  type        = string
  default     = "app"
}

variable "master_username" {
  type    = string
  default = "postgres"
}

variable "kms_key_arn" {
  description = "KMS key ARN for storage encryption. Null means the AWS-managed default RDS encryption key (aws/rds) is used instead of a customer-managed key."
  type        = string
  default     = null
}

# Safe, production-oriented defaults. This module must not hardcode staging's
# nightly-teardown behavior - envs/staging is expected to override all three
# explicitly. See README for why each direction is safe where it's used.
variable "backup_retention_period" {
  type    = number
  default = 7
}

variable "skip_final_snapshot" {
  type    = bool
  default = false
}

variable "deletion_protection" {
  type    = bool
  default = true
}
