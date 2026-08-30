# AmazonEKSEditPolicy (the access policy associated with ci_deploy in
# envs/staging/main.tf) does NOT cover the external-secrets.io API group -
# confirmed against AWS's own published permission table
# (docs.aws.amazon.com/eks/latest/userguide/access-policy-permissions.html)
# for AmazonEKSEditPolicy: every rule in it is scoped to apiGroups
# apps/autoscaling/batch/discovery.k8s.io/extensions/networking.k8s.io/
# policy or the core ("") group - external-secrets.io appears nowhere, and
# there is no wildcard apiGroup rule. So ci_deploy's `helm upgrade` (which
# needs to create/update the ExternalSecret in charts/app/) needs this
# supplementary grant, namespaced only - nothing cluster-scoped, and no
# second access policy association (AWS access policies aren't
# composable/addable a la carte; this is an ordinary Kubernetes Role
# instead).
resource "kubernetes_role_v1" "ci_deploy_external_secrets" {
  metadata {
    name      = "ci-deploy-external-secrets"
    namespace = kubernetes_namespace_v1.staging.metadata[0].name
  }

  rule {
    api_groups = ["external-secrets.io"]
    resources  = ["externalsecrets"]
    # `watch` was missing here and broke every automated deploy: Helm 4's
    # --wait uses a generic kstatus-based waiter that watches every
    # resource a release creates, custom resources included, not just a
    # fixed list of built-in kinds - not something apparent from reading
    # this Role in isolation, only from the actual failure it caused
    # (run 33335905391): "cannot watch resource "externalsecrets" ...
    # uninstallation completed with 1 error(s)" during --atomic's rollback.
    verbs = ["create", "get", "list", "watch", "patch", "update", "delete"]
  }
}

# Bound to a Kubernetes Group, not to the access entry's `username`. For a
# role principal, EKS derives that username as
# "arn:aws:sts::<acct>:assumed-role/<role>/{{SessionName}}" - a template
# EKS substitutes the real, per-invocation session name into at
# authentication time, not a literal string. A RoleBinding subject must
# match the authenticated identity exactly, so binding to that literal
# templated string would never match any real request (each GitHub Actions
# run picks its own session name). var.ci_deploy_kubernetes_group is a
# fixed, stable group name applied to every session of this role via the
# access entry's kubernetes_groups (modules/eks/access_entries.tf) -
# exactly what `--kubernetes-groups` on an access entry is documented to
# be for: "the value for name that you've specified for kind: Group as a
# subject in a Kubernetes RoleBinding".
resource "kubernetes_role_binding_v1" "ci_deploy_external_secrets" {
  metadata {
    name      = "ci-deploy-external-secrets"
    namespace = kubernetes_namespace_v1.staging.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.ci_deploy_external_secrets.metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = var.ci_deploy_kubernetes_group
    api_group = "rbac.authorization.k8s.io"
  }
}
