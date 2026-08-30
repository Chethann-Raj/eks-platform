resource "kubernetes_namespace_v1" "external_secrets" {
  metadata {
    name = "external-secrets"
  }
}

data "aws_iam_policy_document" "external_secrets_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = "${local.name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.external_secrets_assume.json
}

# Scoped to exactly the one RDS master user secret, passed in as a
# variable - no wildcards. This role can read this secret and nothing else.
data "aws_iam_policy_document" "external_secrets_rds" {
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [var.rds_master_user_secret_arn]
  }
}

resource "aws_iam_role_policy" "external_secrets_rds" {
  name   = "${local.name}-external-secrets-rds"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets_rds.json
}

resource "kubernetes_service_account_v1" "external_secrets" {
  metadata {
    name      = "external-secrets"
    namespace = kubernetes_namespace_v1.external_secrets.metadata[0].name

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.external_secrets.arn
    }
  }
}

# Chart version confirmed live against
# https://charts.external-secrets.io/index.yaml on 2026-08-30 (redirects to
# https://external-secrets.io/index.yaml) - 2.10.0 was the newest entry,
# appVersion v2.10.0.
#
# This installs the operator and its IRSA plumbing only. No
# ClusterSecretStore or ExternalSecret object is created here - that wiring
# (which namespace the app's Secret materializes into, its key mapping,
# refresh interval) wasn't in scope for this pass and is a follow-up once
# the app namespace exists.
resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = "2.10.0"
  namespace  = kubernetes_namespace_v1.external_secrets.metadata[0].name

  # See the comment on helm_release.aws_load_balancer_controller for why
  # atomic (implies wait - not also set here) and an explicit timeout are
  # on every helm_release in this module.
  atomic  = true
  timeout = 300

  set = [
    {
      name  = "serviceAccount.create"
      value = "false"
    },
    {
      name  = "serviceAccount.name"
      value = kubernetes_service_account_v1.external_secrets.metadata[0].name
    },
  ]

  # This chart creates Services. LBC's Service mutator webhook is disabled
  # now (see helm_release.aws_load_balancer_controller), which already
  # closes the specific failure mode that hit this release - but LBC is
  # also just a more foundational, cluster-wide controller than this one,
  # so it still makes sense for its install to fully finish and settle
  # first rather than racing it. ExternalDNS creates no Services and has
  # no such ordering need, so it deliberately stays parallel (no
  # depends_on added there).
  depends_on = [
    kubernetes_service_account_v1.external_secrets,
    helm_release.aws_load_balancer_controller,
  ]
}
