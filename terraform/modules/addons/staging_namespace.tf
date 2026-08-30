# The ci_deploy role only has AmazonEKSEditPolicy scoped to the "staging"
# namespace (see envs/staging/main.tf's access_entries) - it can act
# *within* that namespace but must never be able to create it. Created
# here so .github/workflows/deploy.yml's `helm upgrade --install` never
# needs `--create-namespace`, which would be a cluster-scoped write that
# role doesn't have.
resource "kubernetes_namespace_v1" "staging" {
  metadata {
    name = "staging"
  }
}
