variable "project" {
  description = "Project tag / naming prefix component."
  type        = string
}

variable "environment" {
  description = "Environment tag / naming prefix component (e.g. staging)."
  type        = string
}

variable "aws_region" {
  description = "AWS region - passed explicitly to the Load Balancer Controller chart rather than relying on IMDS auto-detection."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID from the vpc module, passed to the Load Balancer Controller chart."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name from the eks module."
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS cluster's OIDC provider ARN from the eks module. Reused for every IRSA role in this module - never a second provider."
  type        = string
}

variable "oidc_provider_url" {
  description = "EKS cluster's OIDC provider URL (with https://) from the eks module."
  type        = string
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID from the persistent layer's remote state. Scopes ExternalDNS's write access to exactly this zone."
  type        = string
}

variable "domain_name" {
  description = "Domain ExternalDNS manages records for."
  type        = string
  default     = "chethanraj.site"
}

variable "rds_master_user_secret_arn" {
  description = "Secrets Manager ARN of the RDS-managed master user secret, from the rds module. Scopes External Secrets Operator's IRSA role to exactly this one secret - no wildcards."
  type        = string
}

variable "ci_deploy_kubernetes_group" {
  description = "Kubernetes group name assigned to the ci_deploy access entry (modules/eks's access_entries kubernetes_groups) - ci_deploy_rbac.tf binds its Role to this group, not to the access entry's raw username (which is a per-session template, not a stable string - see modules/eks's access_entries variable doc)."
  type        = string
}
