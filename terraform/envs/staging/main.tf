locals {
  # Matches the naming pattern each module derives internally as
  # "${var.project}-${var.environment}" (see e.g. modules/eks/main.tf's
  # local.name) - computed here too only so it can be used in the
  # kubernetes.io/cluster/<name> subnet discovery tag below, before the eks
  # module (which owns the real cluster name) exists.
  cluster_name = "${var.project}-${var.environment}"
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
    ci_deploy = {
      principal_arn     = data.terraform_remote_state.persistent.outputs.ci_deploy_role_arn
      access_policy     = "AmazonEKSEditPolicy"
      access_scope_type = "namespace"
      namespaces        = ["staging"]
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

  # The rds module's defaults are production-oriented (see its README).
  # This environment is destroyed and rebuilt nightly, so all three are
  # explicitly overridden here rather than left at the module's defaults.
  deletion_protection     = false # staging only, nightly teardown
  skip_final_snapshot     = true  # staging only, nightly teardown
  backup_retention_period = 0     # staging only, nightly teardown
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

  # Module-level depends_on, not per-resource: this module's helm_release
  # resources can't reference module.eks.aws_eks_node_group.default
  # directly (cross-module resource addresses aren't valid depends_on
  # targets from inside a child module). Depending on the whole module.eks
  # call is a strictly stronger guarantee that includes the nodegroup, and
  # is symmetric on destroy too - see terraform/modules/addons/README.md.
  depends_on = [module.eks]
}
