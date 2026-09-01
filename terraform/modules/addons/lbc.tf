# lbc_iam_policy.json is AWS's own published minimum IAM policy for this
# exact chart's app version - downloaded verbatim from
# https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.5.0/docs/install/iam_policy.json
# (v3.5.0 matching helm_release.aws_load_balancer_controller's pinned
# version below), not hand-transcribed. Several of its 16 statements use
# "Resource": "*" - that's AWS's own document, not a choice made here. A
# wildcard is genuinely unavoidable here: the controller's read-only
# Describe*/Get*/List* calls against EC2 and ELBv2 (discovering existing
# subnets, SGs, ENIs, listeners, etc. account-wide) have no resource-level
# permission support in IAM at all, and its write actions
# (CreateLoadBalancer, CreateTargetGroup, ...)
# can't be scoped to specific ARNs upfront because the controller creates
# those ALBs/target groups itself, dynamically, in response to Ingress/
# Service objects that don't exist yet at policy-authoring time. AWS scopes
# the write actions with aws:ResourceTag conditions instead (visible in the
# JSON) - that's the closest this policy can get to least-privilege, and
# it's what upstream ships.
data "aws_iam_policy_document" "lbc_assume" {
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
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lbc" {
  name               = "${local.name}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.lbc_assume.json
}

resource "aws_iam_policy" "lbc" {
  name   = "${local.name}-aws-load-balancer-controller"
  policy = file("${path.module}/lbc_iam_policy.json")
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

resource "kubernetes_service_account_v1" "lbc" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"

    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.lbc.arn
    }

    labels = {
      "app.kubernetes.io/name"      = "aws-load-balancer-controller"
      "app.kubernetes.io/component" = "controller"
    }
  }
}

# Chart version confirmed live against the chart repo's index.yaml
# (https://aws.github.io/eks-charts) on 2026-08-30 - 3.5.0 was the newest
# entry, appVersion v3.5.0. Not reused from memory.
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.5.0"
  namespace  = "kube-system"

  # atomic implies wait (confirmed against the pinned helm provider 3.2.0's
  # own schema: "The wait flag will be set automatically if atomic is
  # used") - wait is deliberately not also set here, that would be
  # redundant with what atomic already does. Without atomic, a failed
  # install leaves the release in `failed` status, which Terraform will not
  # create over on the next apply - re-running requires a manual `helm
  # uninstall` first, which is exactly what happened here for
  # external_secrets. timeout is explicit rather than left at the
  # provider's default so a hang has a bounded, known worst case; 5m is
  # comfortable for these three lightweight controller-only charts (no
  # stateful workloads, no first-time large image pulls expected).
  atomic  = true
  timeout = 300

  set = [
    {
      name  = "clusterName"
      value = var.cluster_name
    },
    {
      name  = "region"
      value = var.aws_region
    },
    {
      name  = "vpcId"
      value = var.vpc_id
    },
    {
      name  = "replicaCount"
      value = "2"
    },
    {
      # This webhook (mservice.elbv2.k8s.aws, failurePolicy: Fail - both
      # confirmed against the pinned v3.5.0 chart's templates/webhook.yaml
      # and values.yaml) exists only to stamp spec.loadBalancerClass onto
      # every new type: LoadBalancer Service cluster-wide, so LBC becomes
      # the default provisioner for those and creates an NLB. This
      # platform routes everything through Ingress/ALB, never a
      # LoadBalancer-type Service - the webhook does nothing
      # useful here while sitting in front of every Service creation in
      # the cluster with failurePolicy: Fail. On a from-scratch nightly
      # rebuild, that is a live failure mode for any other chart creating
      # a Service before LBC's own pods are serving on :9443 - which is
      # exactly how external_secrets failed here (a ~28s window where the
      # webhook config existed but had no ready endpoints yet).
      name  = "enableServiceMutatorWebhook"
      value = "false"
    },
    {
      name  = "serviceAccount.create"
      value = "false"
    },
    {
      name  = "serviceAccount.name"
      value = kubernetes_service_account_v1.lbc.metadata[0].name
    },
  ]

  depends_on = [kubernetes_service_account_v1.lbc]
}
