# kube-prometheus-stack: Prometheus + Grafana. Alertmanager is a deliberate
# scope cut - CLAUDE.md §15. Loki (below, helm_release.loki) is not cut -
# centralized logging is a required part of the assignment.
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

# Chart version confirmed live against
# https://grafana.github.io/helm-charts/index.yaml on 2026-08-31 - 7.3.0 was
# the newest entry, appVersion 3.6.12.
#
# This config is deeply nested (deploymentMode, per-component replica
# zeroing, an explicit schemaConfig) - past a certain depth, `set` entries
# stop being more readable than the YAML they're setting, so this release
# uses `values = [yamlencode(...)]` instead of the `set` list every other
# helm_release in this module uses. The nesting is inherent to the chart,
# not a style choice made for its own sake.
resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = "7.3.0"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  # atomic = false, deliberately different from every other release in this
  # module: a failed Loki install is exactly what atomic's automatic
  # uninstall destroyed the evidence for the first time this was applied
  # (10m of "context deadline exceeded", then nothing left to inspect - see
  # CHALLENGES.md). A failed install should be left in place for `kubectl
  # describe`/`logs` to actually diagnose, not rolled back before anyone can
  # look at it. timeout stays at 600 - the CRD/component count reasoning on
  # helm_release.kube_prometheus_stack's timeout doesn't apply here (this
  # chart has no CRDs), but a SingleBinary Loki install still isn't
  # instant, and a bounded worst case is still better than none.
  atomic  = false
  timeout = 600

  values = [
    yamlencode({
      deploymentMode = "SingleBinary"

      loki = {
        auth_enabled = false
        commonConfig = {
          replication_factor = 1
        }
        storage = {
          type = "filesystem"
        }
        # Must be set explicitly - the chart's own schemaConfig default is
        # {} and rendering fails without one ("a real Loki install requires
        # a proper schemaConfig", per the chart's own values.yaml comment).
        # object_store: filesystem matches storage.type above - no S3/GCS/
        # Azure bucket and no minio sidecar, just local disk (an explicit
        # emptyDir - see singleBinary.extraVolumes below, not persistence).
        schemaConfig = {
          configs = [
            {
              from         = "2024-04-01"
              store        = "tsdb"
              object_store = "filesystem"
              schema       = "v13"
              index = {
                prefix = "index_"
                period = "24h"
              }
            }
          ]
        }
        limits_config = {
          retention_period = "48h"
        }
      }

      singleBinary = {
        replicas = 1
        # No PVC, deliberately: same reasoning as
        # prometheus.prometheusSpec.storageSpec above - this environment is
        # destroyed nightly so Loki's chunks have no value across a
        # rebuild, and an EBS volume would be one more resource
        # scripts/pre-destroy.sh has to sequence correctly before the
        # cluster goes away.
        #
        # persistence.enabled: false is NOT enough on its own, unlike
        # Prometheus: confirmed against the pinned 7.3.0 chart's own
        # templates/single-binary/statefulset.yaml - the `storage`
        # volume/volumeMount at /var/loki only exists at all
        # `{{- if .Values.singleBinary.persistence.enabled }}` (as a PVC).
        # There is no chart-side fallback to an emptyDir the way
        # prometheus-operator falls back when storageSpec is left unset -
        # disabling persistence here just omits the volume entirely. The
        # loki container also runs readOnlyRootFilesystem: true (the
        # chart's own hardened default), and the ruler module's WAL
        # directory (rulerConfig.wal.dir, default /var/loki/ruler-wal)
        # tries to mkdir under /var/loki unconditionally on startup - with
        # no volume mounted there and a read-only root filesystem, that
        # mkdir fails and the process exits 1 immediately
        # ("error initialising module: ruler-storage"). Reproduced live:
        # see CHALLENGES.md. extraVolumes/extraVolumeMounts below supply
        # the emptyDir explicitly instead - confirmed via `helm template`
        # against this exact chart version+values that it actually lands a
        # writable /var/loki (an emptyDir, not a PVC) before this was
        # committed.
        persistence = {
          enabled = false
        }
        extraVolumes = [
          {
            name     = "storage"
            emptyDir = {}
          }
        ]
        extraVolumeMounts = [
          {
            name      = "storage"
            mountPath = "/var/loki"
          }
        ]
        resources = {
          requests = {
            cpu    = "100m"
            memory = "256Mi"
          }
          limits = {
            memory = "512Mi"
          }
        }
      }

      # SingleBinary mode runs everything in the one singleBinary pod above -
      # read/write/backend still default to nonzero replicas regardless of
      # deploymentMode, so they're zeroed explicitly or the chart schedules
      # pods this deployment mode has no use for.
      read    = { replicas = 0 }
      write   = { replicas = 0 }
      backend = { replicas = 0 }

      # No gateway (nginx) fronting Loki - helm_release.promtail and the
      # Grafana datasource ConfigMap below both talk to the singleBinary
      # Service directly (loki.monitoring.svc.cluster.local:3100, confirmed
      # by rendering this exact chart+values with `helm template` and
      # reading the rendered Service name back - not assumed). One less
      # component sized against this node group for no purpose here.
      gateway = { enabled = false }

      # Both default to a memcached deployment requesting several Gi each -
      # confirmed against the chart's own values.yaml - which alone would
      # blow past this node group's smallest node (3.07Gi allocatable).
      # Disabled outright rather than resized: log volume at this scale
      # doesn't need a chunks/results cache to begin with.
      chunksCache = {
        enabled = false
      }
      resultsCache = {
        enabled = false
      }

      # lokiCanary writes and reads back synthetic test logs on a schedule
      # purely to alert on Loki's own health, and `test` is the chart's Helm
      # test-hook pod - neither is core logging function, and both are one
      # more pod/schedule this node group doesn't need to carry.
      lokiCanary = {
        enabled = false
      }
      test = {
        enabled = false
      }

      # No alerting rules are configured and Alertmanager is already cut
      # (helm_release.kube_prometheus_stack's alertmanager.enabled: false
      # above) - the ruler module is dead weight here. NOTE: this alone
      # does not fix the /var/loki crash above - the compactor and the
      # index/chunk WAL also write under /var/loki regardless of whether
      # the ruler runs. The writable emptyDir (extraVolumes/
      # extraVolumeMounts above) is the actual fix; this just removes one
      # more consumer of that directory.
      ruler = {
        enabled = false
      }
    })
  ]
}

# Chart version confirmed live against
# https://grafana.github.io/helm-charts/index.yaml on 2026-08-31 - 6.17.1
# was the newest entry, appVersion 3.5.1.
#
# promtail over Grafana Alloy: Alloy is the actively-developed collector and
# promtail is itself upstream-frozen in maintenance mode - but Alloy's
# config is its own River-based language, and getting a DaemonSet doing
# exactly this (tail every container's logs, ship to one Loki endpoint,
# nothing else) right in River is meaningfully more surface area than the
# one `config.clients[0].url` override this needs under promtail. promtail
# was chosen here for config simplicity under a deadline - migrating to
# Alloy later is a reasonable follow-up, not a correctness gap today.
resource "helm_release" "promtail" {
  name       = "promtail"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  version    = "6.17.1"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  atomic  = true
  timeout = 300

  set = [
    # loki.monitoring.svc.cluster.local, not the chart's own default
    # (http://loki-gateway/loki/api/v1/push) - helm_release.loki disables
    # the gateway entirely (gateway.enabled: false above), so this points
    # straight at the singleBinary Service instead. Service name confirmed
    # by `helm template`-rendering helm_release.loki's exact chart+version+
    # values and reading the rendered Service objects back, not guessed:
    # release name "loki" + chart name "loki" collapse to a Service
    # literally named "loki" (see loki.fullname's `contains $name
    # .Release.Name` branch in the chart's _helpers.tpl).
    {
      name  = "config.clients[0].url"
      value = "http://loki.${kubernetes_namespace_v1.monitoring.metadata[0].name}.svc.cluster.local:3100/loki/api/v1/push"
    },
    {
      name  = "resources.requests.cpu"
      value = "50m"
    },
    {
      name  = "resources.requests.memory"
      value = "128Mi"
    },
    {
      name  = "resources.limits.memory"
      value = "256Mi"
    },
  ]

  depends_on = [
    helm_release.loki,
  ]
}

# Wires Loki into Grafana as a datasource without touching
# helm_release.kube_prometheus_stack at all: that release's grafana subchart
# already runs with sidecar.datasources.enabled: true (kube-prometheus-
# stack's own values.yaml override of the grafana subchart's default, which
# is otherwise false) and searches its own namespace ("monitoring", where
# this ConfigMap lives) for ConfigMaps carrying the `grafana_datasource`
# label - it doesn't matter what value the label has, only that it's
# present (the grafana subchart's own sidecar.datasources.labelValue
# defaults to "", which the sidecar treats as "match on key, any value").
# Grafana picks this up live, no helm_release upgrade or pod restart needed.
resource "kubernetes_config_map_v1" "grafana_datasource_loki" {
  metadata {
    name      = "${local.name}-grafana-datasource-loki"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    labels = {
      grafana_datasource = "1"
    }
  }

  data = {
    "loki-datasource.yaml" = yamlencode({
      apiVersion = 1
      datasources = [
        {
          name      = "Loki"
          type      = "loki"
          access    = "proxy"
          url       = "http://loki.${kubernetes_namespace_v1.monitoring.metadata[0].name}.svc.cluster.local:3100"
          isDefault = false
        }
      ]
    })
  }
}
