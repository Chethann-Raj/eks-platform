locals {
  # Matches the naming pattern each module derives internally as
  # "${var.project}-${var.environment}" (see e.g. modules/eks/main.tf's
  # local.name) - computed here too only so it can be used in the
  # kubernetes.io/cluster/<name> subnet discovery tag below, before the eks
  # module (which owns the real cluster name) exists.
  cluster_name = "${var.project}-${var.environment}"

  # Kubernetes group the ci_production access entry is tagged with, so
  # modules/addons' ci_deploy_rbac.tf can bind a namespaced RoleBinding to
  # a stable group name instead of the access entry's per-session-variable
  # `username` - see the access_entries variable doc in modules/eks for why
  # that distinction matters. "eks-platform-ci-production", not
  # "eks-platform-ci-deploy" (staging's group, ${var.project}-ci-deploy) -
  # this was copy-pasted from envs/staging/main.tf without being updated,
  # same bug as the principal_arn below. See CHALLENGES.md.
  ci_production_k8s_group = "${var.project}-ci-production"
}

# Never write the account ID literally - CLAUDE.md §2. Used below for the
# terraform-admin access entry.
data "aws_caller_identity" "current" {}

# Persistent layer's remote state, read-only. terraform/persistent/backend.tf
# is the source of truth for this bucket/key - read, not guessed.
data "terraform_remote_state" "persistent" {
  backend = "s3"

  config = {
    bucket = "chethanraj-eks-platform-tfstate"
    key    = "persistent/terraform.tfstate"
    region = "ap-south-1"
  }
}

module "vpc" {
  source = "../../modules/vpc"

  project     = var.project
  environment = var.environment

  # Lets the AWS Load Balancer Controller (Phase 2) and cluster-owned
  # resources discover these subnets by cluster, in addition to the
  # kubernetes.io/role/elb / internal-elb tags the vpc module always sets.
  # local.cluster_name here must match the eks module's own internal naming.
  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

module "eks" {
  source = "../../modules/eks"

  project     = var.project
  environment = var.environment

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  kubernetes_version = var.kubernetes_version

  # Persistent, not staging - see terraform/persistent/kms.tf and its
  # README for why this key must never live in a nightly-destroyed layer.
  kms_key_arn = data.terraform_remote_state.persistent.outputs.eks_kms_key_arn

  # CLAUDE.md §8: both access entries required, or Phase 3's first
  # `helm upgrade` fails with an authentication error.
  #
  # access_policy is a bare EKS access policy NAME, not an ARN - the eks
  # module builds the arn:aws:eks::aws:cluster-access-policy/... ARN
  # itself. These are NOT IAM policy ARNs (arn:aws:iam::aws:policy/...) -
  # see the comment in modules/eks/access_entries.tf.
  access_entries = {
    admin = {
      principal_arn     = data.aws_caller_identity.current.arn
      access_policy     = "AmazonEKSClusterAdminPolicy"
      access_scope_type = "cluster"
    }
    # ci_production, not ci_deploy - this file was originally copy-pasted
    # from envs/staging/main.tf and referenced the STAGING role
    # (ci_deploy_role_arn) scoped to the STAGING namespace here, which would
    # have granted this cluster's edit access to the wrong role entirely
    # (one whose trust policy doesn't even permit assuming it from a
    # production-environment-gated job) and pointed it at a namespace that
    # doesn't exist in this cluster. Fixed to reference
    # ci_production_role_arn (terraform/persistent/oidc.tf's
    # aws_iam_role.ci_production, trusted only for `sub:
    # ...:environment:production`) scoped to the "production" namespace.
    # See CHALLENGES.md.
    ci_production = {
      principal_arn     = data.terraform_remote_state.persistent.outputs.ci_production_role_arn
      access_policy     = "AmazonEKSEditPolicy"
      access_scope_type = "namespace"
      namespaces        = ["production"]
      # AmazonEKSEditPolicy does not cover external-secrets.io (confirmed
      # against AWS's own published permission table for this policy -
      # see CHALLENGES.md). This group is what modules/addons'
      # ci_deploy_rbac.tf binds its supplementary Role to.
      kubernetes_groups = [local.ci_production_k8s_group]
    }
  }
}

module "rds" {
  source = "../../modules/rds"

  project     = var.project
  environment = var.environment

  vpc_id                 = module.vpc.vpc_id
  private_subnet_ids     = module.vpc.private_subnet_ids
  node_security_group_id = module.eks.node_security_group_id

  engine_version = var.engine_version
  instance_class = var.instance_class

  # AWS-managed RDS key, not a customer-managed one - no KMS infrastructure
  # this environment needs otherwise.
  kms_key_arn = null

  # Unlike envs/staging, this environment is not torn down nightly - these
  # were copied from envs/staging/main.tf's overrides (see CHALLENGES.md)
  # and left the database with no deletion protection, no final snapshot on
  # destroy, and zero backup retention. Set explicitly here instead of left
  # at the rds module's own defaults so the intent is visible in this file
  # without having to go read the module.
  deletion_protection     = true
  skip_final_snapshot     = false
  backup_retention_period = 7
}

module "addons" {
  source = "../../modules/addons"

  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region

  vpc_id       = module.vpc.vpc_id
  cluster_name = module.eks.cluster_name

  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url

  hosted_zone_id = data.terraform_remote_state.persistent.outputs.hosted_zone_id

  rds_master_user_secret_arn = module.rds.master_user_secret_arn

  ci_deploy_kubernetes_group = local.ci_production_k8s_group

  # Module-level depends_on, not per-resource: this module's helm_release
  # resources can't reference module.eks.aws_eks_node_group.default
  # directly (cross-module resource addresses aren't valid depends_on
  # targets from inside a child module). Depending on the whole module.eks
  # call is a strictly stronger guarantee that includes the nodegroup, and
  # is symmetric on destroy too - see terraform/modules/addons/README.md.
  depends_on = [module.eks]
}
