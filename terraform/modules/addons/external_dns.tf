data "aws_iam_policy_document" "external_dns_assume" {
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
      values   = ["system:serviceaccount:kube-system:external-dns"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_dns" {
  name               = "${local.name}-external-dns"
  assume_role_policy = data.aws_iam_policy_document.external_dns_assume.json
}

# Checked against the upstream ExternalDNS Route53 IAM reference
# (kubernetes-sigs/external-dns docs/tutorials/aws.md) rather than
# reproducing the request's exact action grouping from memory: it groups
# ChangeResourceRecordSets AND ListResourceRecordSets together, both scoped
# to a hosted zone ARN (arn:aws:route53:::hostedzone/<id>) - Route53 does
# support resource-level permissions for both. Only ListHostedZones is
# genuinely unscopable: it enumerates every hosted zone in the account, and
# Route53 has no resource-level permission support for that action at all.
# So "*" is used for ListHostedZones only, since that's genuinely
# unavoidable - not for ListResourceRecordSets, which stays scoped to this
# one zone instead of defaulting to "*" for convenience.
data "aws_iam_policy_document" "external_dns" {
  statement {
    sid    = "ChangeAndListThisZoneOnly"
    effect = "Allow"
    actions = [
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets",
    ]
    resources = ["arn:aws:route53:::hostedzone/${var.hosted_zone_id}"]
  }

  statement {
    sid       = "ListHostedZonesAccountWide"
    effect    = "Allow"
    actions   = ["route53:ListHostedZones"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "external_dns" {
  name   = "${local.name}-external-dns-route53"
  role   = aws_iam_role.external_dns.id
  policy = data.aws_iam_policy_document.external_dns.json
}

resource "kubernetes_service_account_v1" "external_dns" {
  metadata {
    name      = "external-dns"
    namespace = "kube-system"

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.external_dns.arn
    }
  }
}

# Chart version confirmed live against
# https://kubernetes-sigs.github.io/external-dns/index.yaml on 2026-08-30 -
# 1.21.1 was the newest entry, appVersion 0.21.0.
# txtOwnerId = the cluster name, not a fixed string: staging is destroyed
# and rebuilt nightly, and ExternalDNS's TXT-record ownership tracking
# would otherwise let a rebuilt cluster either refuse to touch records it
# thinks belong to "someone else", or fight over them with whatever ran
# the night before. Tying ownership to the (also freshly-created) cluster
# name sidesteps both.
resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = "1.21.1"
  namespace  = "kube-system"

  # See the comment on helm_release.aws_load_balancer_controller for why
  # atomic (which implies wait - not also set here, redundant) and an
  # explicit timeout are on every helm_release in this module.
  atomic  = true
  timeout = 300

  set = [
    {
      name  = "provider.name"
      value = "aws"
    },
    {
      name  = "policy"
      value = "sync"
    },
    {
      name  = "txtOwnerId"
      value = var.cluster_name
    },
    # policy=sync lets external-dns update or delete records it owns, not
    # just create new ones. Ownership is proven by a companion TXT record
    # naming this txtOwnerId; a record with no matching TXT (or one naming
    # a different owner) is treated as foreign and left untouched. txtPrefix
    # must end in a "." so that ownership TXT forms a real subdomain of the
    # zone (e.g. "txt.chethanraj.site") rather than an invalid name that
    # fails to resolve under it.
    {
      name  = "txtPrefix"
      value = "txt."
    },
    {
      name  = "domainFilters[0]"
      value = var.domain_name
    },
    {
      name  = "serviceAccount.create"
      value = "false"
    },
    {
      name  = "serviceAccount.name"
      value = kubernetes_service_account_v1.external_dns.metadata[0].name
    },
  ]

  depends_on = [kubernetes_service_account_v1.external_dns]
}
