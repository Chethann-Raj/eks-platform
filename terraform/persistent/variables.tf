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

variable "ecr_repository_name" {
  description = "Name of the ECR repository the app image is pushed to."
  type        = string
  default     = "eks-platform"
}
