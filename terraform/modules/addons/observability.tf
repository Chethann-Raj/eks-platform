# kube-prometheus-stack: Prometheus + Grafana only. Loki and Alertmanager
# are a deliberate scope cut - CLAUDE.md §15.
resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

# Grafana has no AWS-native managed-secret equivalent to RDS's
# manage_master_user_password (terraform/modules/rds) - nothing generates
# or rotates this credential outside Terraform for us. random_password's
# `result` therefore does land in the state file as plaintext: the
# `sensitive = true` on that attribute only suppresses it from plan/apply
# CLI output, it does nothing to the state file itself. The state bucket
# has SSE-S3 encryption at rest and public access blocked
# (terraform/bootstrap), which mitigates but doesn't eliminate this -
# anyone with S3 read access to the state object, or `terraform state
# pull`, can recover it in the clear.
#
# The real alternative - never having Terraform materialize the value at
# all - would mean standing up a custom Secrets Manager rotation Lambda
# (Grafana isn't a supported native rotation target the way RDS is), plus
# its IAM role and a rotation schedule, just to generate a login for a
# Grafana instance that (a) is reachable only via kubectl port-forward,
# never off-cluster, and (b) is destroyed and regenerated every night
# regardless. That infrastructure cost isn't justified here - accepting the
# state-file exposure, scoped by the existing state bucket protections, is
# the trade-off being made.
resource "random_password" "grafana_admin" {
  length  = 24
  special = true
}

resource "kubernetes_secret_v1" "grafana_admin" {
  metadata {
    name      = "${local.name}-grafana-admin"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }

  # Key names match the grafana subchart's admin.userKey / admin.passwordKey
  # defaults ("admin-user" / "admin-password") - left at their defaults
  # below (not overridden in the set list) so nothing else has to change.
  data = {
    "admin-user"     = "admin"
    "admin-password" = random_password.grafana_admin.result
  }
}

# Chart version confirmed live against
# https://prometheus-community.github.io/helm-charts/index.yaml on
# 2026-08-31 - 88.6.1 was the newest entry, appVersion v0.93.1 (the bundled
# prometheus-operator's version, not Prometheus itself).
#
# Sizing below is fixed by explicit instruction, not derived from
# CLAUDE.md §13 - this cluster's node group is mixed-instance (one
# m7i-flex.large at 6.94Gi allocatable, two c7i-flex.large at 3.07Gi) and
# torn down nightly, so every component's requests/limits are set low
# enough to schedule on the smallest node, with no nodeSelector/affinity
# pinning anything to a specific node or instance type.
resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "88.6.1"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  # atomic implies wait - see the comment on
  # helm_release.aws_load_balancer_controller for why that's not also set
  # here. timeout is longer than this module's other releases (300s): this
  # chart installs ~30 CRDs via a pre-install hook before the operator
  # itself starts, then brings up Prometheus, Grafana, kube-state-metrics
  # and a node-exporter DaemonSet (one pod per node) - more moving parts
  # and more first-time image pulls than any other single release in this
  # module.
  atomic  = true
  timeout = 600

  set = [
    # Loki and Alertmanager are OUT - deliberate scope cut (CLAUDE.md §15).
    {
      name  = "alertmanager.enabled"
      value = "false"
    },

    {
      name  = "prometheus.prometheusSpec.retention"
      value = "2d"
    },
    {
      name  = "prometheus.prometheusSpec.retentionSize"
      value = "4GB"
    },
    # No storageSpec set anywhere in this list, deliberately: gp3 is
    # WaitForFirstConsumer (storage_class.tf), this environment is
    # destroyed nightly so Prometheus's data has no value across a
    # rebuild, and an EBS volume would be one more resource
    # scripts/pre-destroy.sh has to sequence correctly before the cluster
    # goes away. Leaving storageSpec unset makes prometheus-operator fall
    # back to its own default: an emptyDir on the Prometheus pod.
    {
      name  = "prometheus.prometheusSpec.resources.requests.cpu"
      value = "200m"
    },
    {
      name  = "prometheus.prometheusSpec.resources.requests.memory"
      value = "512Mi"
    },
    # No cpu limit - CFS throttling during a scrape cycle causes scrape
    # timeouts and gaps in the graphs, indistinguishable from a real
    # outage. A short CPU burst is the cheaper failure (CLAUDE.md §13).
    {
      name  = "prometheus.prometheusSpec.resources.limits.memory"
      value = "1536Mi"
    },

    {
      name  = "grafana.persistence.enabled"
      value = "false"
    },
    {
      name  = "grafana.admin.existingSecret"
      value = kubernetes_secret_v1.grafana_admin.metadata[0].name
    },
    {
      name  = "grafana.resources.requests.cpu"
      value = "100m"
    },
    {
      name  = "grafana.resources.requests.memory"
      value = "128Mi"
    },
    {
      name  = "grafana.resources.limits.memory"
      value = "256Mi"
    },
    # No Ingress resource for Grafana - left unset, matching the chart's
    # own default (ingress.enabled: false, service left at ClusterIP).
    # Access is kubectl port-forward only.

    # Subchart value overrides key on the dependency's chart `name`
    # ("kube-state-metrics" / "prometheus-node-exporter"), NOT the
    # kubeStateMetrics/nodeExporter enable-toggle keys those look like at a
    # glance - confirmed against the pinned chart's own Chart.yaml (these
    # dependencies have no alias, so overrides key on `name`, not
    # `condition`). Getting this wrong silently no-ops instead of erroring.
    {
      name  = "kube-state-metrics.resources.requests.cpu"
      value = "10m"
    },
    {
      name  = "kube-state-metrics.resources.requests.memory"
      value = "32Mi"
    },
    {
      name  = "kube-state-metrics.resources.limits.memory"
      value = "128Mi"
    },

    {
      name  = "prometheus-node-exporter.resources.requests.cpu"
      value = "25m"
    },
    {
      name  = "prometheus-node-exporter.resources.requests.memory"
      value = "30Mi"
    },
    {
      name  = "prometheus-node-exporter.resources.limits.memory"
      value = "64Mi"
    },
  ]

  depends_on = [
    kubernetes_secret_v1.grafana_admin,
  ]
}
