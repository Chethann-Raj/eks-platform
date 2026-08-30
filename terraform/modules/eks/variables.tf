variable "project" {
  description = "Project tag / naming prefix component."
  type        = string
}

variable "environment" {
  description = "Environment tag / naming prefix component (e.g. staging)."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID from the vpc module."
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the customer-managed KMS key for EKS Kubernetes Secrets encryption. Created in terraform/persistent/, not here - staging is destroyed nightly, and a key pending deletion keeps its alias for the whole deletion window, which would break the next rebuild's attempt to recreate that alias (and accumulate billable keys pending deletion in the meantime)."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs from the vpc module. Nodes run here."
  type        = list(string)
}

variable "kubernetes_version" {
  description = "EKS version. Pinned per CLAUDE.md §4 - do not use 1.31, it left standard support."
  type        = string
  default     = "1.35"
}

variable "cluster_log_retention_days" {
  description = "CloudWatch Logs retention for the control plane log group this module creates explicitly, so EKS never falls back to creating its own never-expire group."
  type        = number
  default     = 7
}

variable "node_instance_types" {
  description = "Spot instance type pool for the managed nodegroup."
  type        = list(string)
  # Constrained by the AWS account's Free Tier plan, not by preference or by
  # vCPU quota: Free Tier plan accounts can only launch a fixed list of
  # instance types account-wide, regardless of Spot/On-Demand quota
  # headroom. Of that list (t4g.micro, t4g.small, t3.micro, t3.small,
  # m7i-flex.large, c7i-flex.large in ap-south-1), only the two flex types
  # are large enough to be useful EKS nodes - the micro/small types cap out
  # at ~11 pods under the VPC CNI's ENI-based pod density limit, which
  # CoreDNS + kube-proxy + aws-node alone largely consume before any
  # workload pod lands. 2 types = 2 Spot capacity pools, down from the
  # original 4 - less interruption headroom, but the Free Tier plan leaves
  # no other x86_64 option at this size. Flex instances also throttle CPU
  # above their baseline (~40% for large); acceptable for staging's
  # workload, but a scale-up consideration if sustained CPU load grows.
  default = ["m7i-flex.large", "c7i-flex.large"]
}

variable "node_ami_type" {
  description = "Node AMI type. No EKS-optimized AL2 AMI exists from 1.34 onward."
  type        = string
  default     = "AL2023_x86_64_STANDARD"
}

variable "node_capacity_type" {
  description = "SPOT or ON_DEMAND. SPOT per CLAUDE.md §5 - the binding quota is 32 vCPU Spot, not 16 vCPU On-Demand."
  type        = string
  default     = "SPOT"
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_desired_size" {
  description = "Initial desired node count. See main.tf/README for why Terraform ignores drift on this after the first apply."
  type        = number
  default     = 3
}

variable "node_max_size" {
  description = "12 vCPU at 6 nodes x 2 vCPU each - comfortably inside the 32 vCPU Spot quota."
  type        = number
  default     = 6
}

# Addon versions are pinned explicitly (CLAUDE.md §2: no floating "latest").
# These defaults are the versions AWS currently marks as default/recommended
# for Kubernetes 1.35 as of 2026-08-30, read directly via:
#   aws eks describe-addon-versions --addon-name <name> --kubernetes-version 1.35
# Re-run that before bumping, don't guess - EKS deprecates old addon builds.
variable "vpc_cni_version" {
  type    = string
  default = "v1.22.4-eksbuild.3"
}

variable "coredns_version" {
  type    = string
  default = "v1.13.2-eksbuild.21"
}

variable "kube_proxy_version" {
  type    = string
  default = "v1.35.3-eksbuild.21"
}

variable "ebs_csi_version" {
  type    = string
  default = "v1.65.0-eksbuild.1"
}

variable "metrics_server_version" {
  type    = string
  default = "v0.9.0-eksbuild.7"
}

variable "access_entries" {
  description = <<-EOT
    EKS access entries (authentication_mode = "API", not aws-auth). Keyed by
    an arbitrary identifier. The module never hardcodes a principal ARN -
    the caller (envs/staging) passes in both the terraform-admin user and
    the ci_deploy role ARN from the persistent layer's remote state.

    access_policy is a bare EKS access policy NAME (e.g.
    "AmazonEKSClusterAdminPolicy"), not an ARN and not an IAM policy ARN -
    see the comment above policy_arn in access_entries.tf for why. Confirm
    valid names with `aws eks list-access-policies`.

    kubernetes_groups is for binding this principal to a Kubernetes
    Role/RoleBinding (in another module, e.g. modules/addons) when the
    access policy alone doesn't cover everything the principal needs -
    see modules/addons' ci_deploy_rbac.tf for why ci_deploy needs one.
    Bind RoleBindings to the GROUP name here, never to the access entry's
    assigned `username` directly: for a role principal, EKS derives that
    username as "arn:aws:sts::<acct>:assumed-role/<role>/{{SessionName}}"
    - a template, not a literal string - and substitutes the real,
    per-request session name at auth time. A RoleBinding subject is an
    exact string match, so binding to that literal templated username
    would never match any real request. A Kubernetes group name has no
    such per-session variability.

    Example:
      {
        admin = {
          principal_arn     = "arn:aws:iam::123456789012:user/terraform-admin"
          access_policy     = "AmazonEKSClusterAdminPolicy"
          access_scope_type = "cluster"
        }
        ci_deploy = {
          principal_arn     = "arn:aws:iam::123456789012:role/eks-platform-ci-deploy"
          access_policy     = "AmazonEKSEditPolicy"
          access_scope_type = "namespace"
          namespaces        = ["staging"]
          kubernetes_groups = ["eks-platform-ci-deploy"]
        }
      }
  EOT
  type = map(object({
    principal_arn     = string
    access_policy     = string
    access_scope_type = string
    namespaces        = optional(list(string), [])
    kubernetes_groups = optional(list(string), [])
  }))
  default = {}
}
