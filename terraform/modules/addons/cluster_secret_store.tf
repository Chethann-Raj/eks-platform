# ClusterSecretStore is cluster-scoped, unlike ExternalSecret - it lives
# here (with the IRSA role/service account it references) rather than in
# charts/app/, which the namespace-scoped ci_deploy role must never be able
# to create or modify.
#
# This is a helm_release against a tiny local chart, not a
# kubernetes_manifest resource, deliberately. kubernetes_manifest validates
# the manifest against its target CRD's schema during `terraform plan`,
# which means the CRD must already exist *before* that plan runs -
# confirmed against the provider's own official example
# (_examples/kubernetes_manifest/cluster-with-resources in
# hashicorp/terraform-provider-kubernetes), which explicitly requires two
# separate `apply` operations (`-target` first) for exactly this reason.
# On a from-scratch nightly rebuild, the ExternalSecrets CRDs (installed by
# helm_release.external_secrets, below) don't exist until that release has
# already applied - so a single `terraform apply` from zero would fail
# `plan` on a kubernetes_manifest for this, breaking the
# "no manual console steps" rebuild promise. helm_release has no such
# restriction: Helm renders and applies YAML without Terraform needing to
# understand the CRD's schema up front, so ordinary depends_on sequencing
# against helm_release.external_secrets is enough for this to work inside
# one apply.
resource "helm_release" "cluster_secret_store" {
  name      = "cluster-secret-store"
  chart     = "${path.module}/charts/cluster-secret-store"
  namespace = kubernetes_namespace_v1.external_secrets.metadata[0].name

  atomic  = true
  timeout = 300

  set = [
    {
      name  = "name"
      value = "aws-secrets-manager"
    },
    {
      name  = "region"
      value = var.aws_region
    },
  ]

  depends_on = [helm_release.external_secrets]
}
