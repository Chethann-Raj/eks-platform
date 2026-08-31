# The only place in this whole config a provider "aws" {} block exists.
# vpc/eks/rds are child modules - they declare required_providers only and
# inherit this configuration.
provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Both use module.eks's outputs plus an exec-plugin token (`aws eks
# get-token`), never a static bearer token - a static token from
# data.aws_eks_cluster_auth or similar expires in 15 minutes, which a
# from-scratch nightly rebuild (VPC+EKS+RDS, then every helm_release in
# terraform/modules/addons) can easily outlast. The exec plugin re-invokes
# `aws eks get-token` fresh whenever the provider actually needs to
# authenticate, so it's never stale. See terraform/modules/addons/README.md
# for the full reasoning.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.aws_region,
      "--profile", var.aws_profile,
    ]
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", module.eks.cluster_name,
        "--region", var.aws_region,
        "--profile", var.aws_profile,
      ]
    }
  }
}
