variable "aws_region" {
  description = "AWS region for the persistent layer."
  type        = string
  default     = "ap-south-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use."
  type        = string
  default     = "pro"
}

variable "project" {
  description = "Project tag applied to every taggable resource."
  type        = string
  default     = "eks-platform"
}

variable "environment" {
  description = "Environment tag. The persistent layer is not itself an environment - it's shared by all of them."
  type        = string
  default     = "shared"
}

variable "domain_name" {
  description = "Root domain, registered at Namecheap and delegated to the Route53 zone created here."
  type        = string
  default     = "chethanraj.site"
}

variable "github_org" {
  description = "GitHub org/user that owns the repo. Used to scope OIDC trust policies."
  type        = string
  default     = "Chethann-Raj"
}

variable "github_repo" {
  description = "GitHub repo name. Used to scope OIDC trust policies."
  type        = string
  default     = "eks-platform"
}

# GitHub's immutable subject claims: repos created after 2026-07-15
# automatically get a second, ID-based sub claim format alongside the
# legacy name-based one (see CHALLENGES.md, "fourth failure class"). Both
# IDs are numeric and permanent for the life of the account/repo - produced
# by:
#   gh api users/Chethann-Raj --jq '.id'
#   gh api repos/Chethann-Raj/eks-platform --jq '.id'
# Not bare literals in oidc.tf so their provenance (and the commands to
# re-derive them, e.g. after a repo transfer) stays documented at the
# point they're declared.
variable "github_owner_id" {
  description = "Numeric GitHub user/org ID for var.github_org - the immutable half of the new-format sub claim prefix."
  type        = number
  default     = 148512002
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID for var.github_repo - the immutable half of the new-format sub claim prefix."
  type        = number
  default     = 1351373185
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository the app image is pushed to."
  type        = string
  default     = "eks-platform"
}
