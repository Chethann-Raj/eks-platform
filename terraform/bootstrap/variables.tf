variable "aws_region" {
  description = "AWS region for the state bucket."
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
  description = "Environment tag for bootstrap resources. Bootstrap itself is not tied to a single env."
  type        = string
  default     = "shared"
}
