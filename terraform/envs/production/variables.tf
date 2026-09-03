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
  description = "Environment tag / naming prefix component. Unlike envs/staging, this environment is not torn down nightly."
  type        = string
  # Was "staging" - copied from envs/staging/variables.tf and never updated.
  # terraform.tfvars overrides this correctly today (confirmed via
  # `terraform console` - local.cluster_name resolves to
  # "eks-platform-production"), but the default itself was a live landmine:
  # a fresh clone running `terraform plan` in this directory with no
  # terraform.tfvars present (it's gitignored) would have
  # silently planned a second "eks-platform-staging"-named environment
  # instead of failing loudly, colliding with the real one. Fixed to
  # "production" here; see terraform.tfvars.example in this directory.
  default = "production"
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
