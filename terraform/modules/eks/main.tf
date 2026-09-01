locals {
  name = "${var.project}-${var.environment}"
}

# Pre-created explicitly, with a short retention, so that enabling control
# plane logging below does not make EKS auto-create
# /aws/eks/<name>/cluster itself with no expiration ever set.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${local.name}/cluster"
  retention_in_days = var.cluster_log_retention_days
}

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${local.name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# AmazonEKSClusterPolicy carries no KMS permissions, and var.kms_key_arn
# (created in terraform/persistent/) has no key policy statement naming this
# role. Without this, cluster creation fails: EKS can't use the key for
# secrets envelope encryption. Scoped to the one key ARN, not "*".
data "aws_iam_policy_document" "cluster_kms" {
  statement {
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:CreateGrant",
      "kms:ListGrants",
    ]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "cluster_kms" {
  name   = "${local.name}-cluster-kms"
  role   = aws_iam_role.cluster.id
  policy = data.aws_iam_policy_document.cluster_kms.json
}

resource "aws_eks_cluster" "this" {
  name     = local.name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  encryption_config {
    provider {
      key_arn = var.kms_key_arn
    }
    resources = ["secrets"]
  }

  # EKS otherwise auto-installs its own default self-managed vpc-cni,
  # coredns and kube-proxy at cluster creation, at whatever version it
  # currently defaults to. Turning that off means the aws_eks_addon
  # resources in addons.tf are the *only* source of these addons and their
  # versions, with nothing pre-existing to conflict with or silently drift
  # from a version this module doesn't know about.
  bootstrap_self_managed_addons = false

  vpc_config {
    # Private subnets only. The AWS Load Balancer Controller discovers
    # subnets for ALBs/NLBs by the kubernetes.io/role/elb and
    # kubernetes.io/role/internal-elb tags across the whole VPC (see the vpc
    # module) - it does not consult this list. Listing public subnets here
    # too would only place control plane ENIs in IGW-routable subnets, with
    # no benefit to the LBC or anything else.
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    # Deliberate: GitHub-hosted runners use a large, rotating IP range that
    # can't meaningfully be allowlisted, and CI deploys via `helm upgrade`
    # from Actions. The security boundary is IAM + EKS Access Entries + RBAC
    # (see access_entries.tf), not the network ACL. Control plane audit
    # logging (enabled_cluster_log_types below) makes access attributable.
    # See the root README for the full reasoning.
    public_access_cidrs = ["0.0.0.0/0"]
  }

  access_config {
    authentication_mode = "API"
    # Access is granted purely through the access_entries variable, not
    # through this implicit "whoever ran apply is admin" shortcut - so the
    # admin grant is declarative, in state, and identical whether it's
    # applied by terraform-admin or anyone else.
    bootstrap_cluster_creator_admin_permissions = false
  }

  upgrade_policy {
    # Explicit so the cluster can never silently drift into paid extended
    # support.
    support_type = "STANDARD"
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_iam_role_policy.cluster_kms,
    aws_cloudwatch_log_group.cluster,
  ]
}
