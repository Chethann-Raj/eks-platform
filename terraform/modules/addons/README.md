# terraform/modules/addons

Platform addons layered onto the already-running cluster: default gp3
storage, AWS Load Balancer Controller, ExternalDNS, and External Secrets
Operator (secret ARNs listed explicitly below, never wildcarded).

## Why this module needs providers the eks module doesn't

`terraform/modules/eks/` only ever talks to the AWS API - creating a
cluster doesn't require talking *to* the cluster. This module does: a
`kubernetes_storage_class_v1`, `helm_release`, etc. all make Kubernetes API
calls against the cluster itself. That means `kubernetes` and `helm`
provider configuration, which - same rule as every other module here - only
exists once, in `terraform/envs/staging/providers.tf`, not in this module.

That root-level configuration uses the eks module's `cluster_endpoint` and
`cluster_certificate_authority_data` outputs plus an **exec-plugin token**
(`aws eks get-token`), not a static bearer token:

```hcl
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region, "--profile", var.aws_profile]
  }
}
```

A static token from `data "aws_eks_cluster_auth"` (or hand-copied from
`aws eks get-token`) is only valid for 15 minutes. Any `terraform plan`/
`apply` that takes longer than that - which a from-scratch nightly rebuild
absolutely can, between VPC/EKS/RDS creation and every `helm_release` in
this module - would have that token expire mid-run, and the *next*
`apply` after that would start with an already-dead token baked into
whatever was cached. The exec plugin instead re-invokes `aws eks get-token`
fresh, every time the provider actually needs to authenticate, so it's
never stale.

## gp3 default StorageClass + gp2 patch

`kubernetes_storage_class_v1.gp3` creates a new default StorageClass
(`gp3`, encrypted, `WaitForFirstConsumer`, `Delete` reclaim). EKS already
ships a default `gp2` StorageClass as part of standard cluster bootstrap -
not something any Terraform resource here owns or created. Two default
StorageClasses is an error state (a PVC with no `storageClassName` becomes
ambiguous), so `kubernetes_annotations.gp2_not_default` patches just the
`storageclass.kubernetes.io/is-default-class` annotation on that existing
`gp2` object down to `"false"`, rather than trying to redefine or replace
it outright. This patch is not optional - it must ship in the same apply as
the new default, or the cluster briefly has two.

## AWS Load Balancer Controller

IRSA role trusts the eks module's existing OIDC provider
(`var.oidc_provider_arn`/`var.oidc_provider_url`) - no second provider is
created. Its IAM policy (`lbc_iam_policy.json`) is AWS's own published
policy for this exact chart version, downloaded verbatim rather than
hand-transcribed - see the comment in `lbc.tf` for the source URL and why
several of its statements are unavoidably `Resource: "*"` - many of its
read-only EC2/ELBv2 calls have no resource-level IAM support at all, and
its write actions can't be scoped to ARNs that don't exist until the
controller creates them.

Chart version `3.5.0`, confirmed live against
`https://aws.github.io/eks-charts/index.yaml` (newest entry, matching
`appVersion v3.5.0`) rather than reused from memory. `replicaCount = 2` per
the original Phase 2 brief.

## ExternalDNS

IRSA scoped to the persistent layer's hosted zone only. Checked the
upstream ExternalDNS Route53 IAM reference rather than assuming: it turns
out `route53:ListResourceRecordSets` **does** support resource-level
scoping to a hosted zone ARN, same as `route53:ChangeResourceRecordSets` -
both are scoped here to `arn:aws:route53:::hostedzone/<hosted_zone_id>`.
Only `route53:ListHostedZones` genuinely requires `Resource: "*"`: it
enumerates every hosted zone in the account and Route53 has no
resource-level permission model for that action at all. See the comment in
`external_dns.tf`.

`policy = sync`, `domainFilters = [chethanraj.site]`,
`txtOwnerId = var.cluster_name` (not a fixed string) - staging is destroyed
and rebuilt nightly, and tying TXT-record ownership to the cluster name
means a freshly-rebuilt cluster doesn't refuse to touch, or fight over,
records a previous night's (differently-named, if ever renamed) cluster
created.

Chart version `1.21.1`, confirmed live against
`https://kubernetes-sigs.github.io/external-dns/index.yaml` (newest entry,
`appVersion 0.21.0`).

## External Secrets Operator

Installs the operator and its IRSA plumbing (dedicated `external-secrets`
namespace and service account) only. IRSA policy grants exactly
`secretsmanager:GetSecretValue` and `secretsmanager:DescribeSecret` on
`var.rds_master_user_secret_arn` - the one RDS-managed secret, passed in as
a variable, no wildcards.

Chart version `2.10.0`, confirmed live against
`https://charts.external-secrets.io/index.yaml` (redirects to
`https://external-secrets.io/index.yaml`; newest entry, `appVersion
v2.10.0`).

## ClusterSecretStore and the `staging` namespace (Phase 3)

Two more cluster-scoped things landed here once the app existed to need
them - both deliberately **not** in `charts/app/`, because the CI role
(`ci_deploy`) is scoped to `AmazonEKSEditPolicy` on the `staging` namespace
only and must never be able to create a namespace or a cluster-scoped
object:

- `kubernetes_namespace_v1.staging` (`staging_namespace.tf`) - so
  `.github/workflows/deploy.yml`'s `helm upgrade --install` never needs
  `--create-namespace`.
- `helm_release.cluster_secret_store` (`cluster_secret_store.tf`), pointed
  at a tiny local chart (`charts/cluster-secret-store/`) rather than a
  `kubernetes_manifest` resource. `kubernetes_manifest` validates against
  its CRD's schema at `terraform plan` time, which means the CRD must
  already exist *before that plan starts* - confirmed against
  hashicorp/terraform-provider-kubernetes's own official example
  (`_examples/kubernetes_manifest/cluster-with-resources`), which requires
  two separate `apply` operations for exactly this reason. That's
  incompatible with a from-scratch nightly `terraform apply`: the
  ExternalSecrets CRDs don't exist until `helm_release.external_secrets`
  has already applied, earlier in the *same* apply. `helm_release` has no
  such restriction - it just renders and applies YAML - so plain
  `depends_on = [helm_release.external_secrets]` is enough for this to
  work in one apply, which a `kubernetes_manifest` here would not.
  `ExternalSecret` objects (namespaced, unlike `ClusterSecretStore`) are
  created by `charts/app/` instead, which `ci_deploy` is allowed to touch.

The `ClusterSecretStore`'s own chart sets no `spec.provider.aws.auth` -
ESO's controller pod already runs as the IRSA-annotated `external-secrets`
service account, so the AWS SDK picks up those credentials from the pod's
own environment without needing to impersonate a different one.

## ci_deploy's supplementary RBAC for ExternalSecret (`ci_deploy_rbac.tf`)

`AmazonEKSEditPolicy` (the access policy `ci_deploy` is associated with in
`envs/staging/main.tf`) does not cover the `external-secrets.io` API group -
confirmed against AWS's own published permission table for it, not
inferred. `ci_deploy`'s `helm upgrade` needs to create/update the
`ExternalSecret` in `charts/app/`, so `ci_deploy_rbac.tf` adds an ordinary
namespaced Kubernetes `Role` + `RoleBinding` granting exactly
`create`/`get`/`list`/`patch`/`update`/`delete` on `externalsecrets` in the
`staging` namespace - nothing cluster-scoped, and no second access policy
association (AWS's access policies aren't composable a la carte; this is
deliberately just an ordinary Kubernetes RBAC grant instead).

The `RoleBinding` binds to a **Kubernetes Group**
(`var.ci_deploy_kubernetes_group`), never to the access entry's `username`.
For a role principal, EKS derives that username as
`arn:aws:sts::<acct>:assumed-role/<role>/{{SessionName}}` - a template it
substitutes the real, per-invocation session name into at authentication
time, not a literal string. Every GitHub Actions run picks its own session
name, so a `RoleBinding` subject bound to that literal templated string
would never match any real request. The group name is instead set directly
on the access entry via `kubernetes_groups`
(`modules/eks/access_entries.tf`) - `--kubernetes-groups` on an access
entry is documented as exactly "the value for name that you've specified
for `kind: Group`", with no per-session variability.

## RDS password rotation vs. env-var Secrets - resolved, Reloader is no longer needed

`manage_master_user_password` (the rds module) means AWS rotates that
Secrets Manager secret's value on its own schedule, not on any schedule
this Terraform config controls. An app that read it into an environment
variable would only ever see the value that was current when its container
started - env vars are frozen at container start, and Kubernetes never
re-injects them into a running container when the backing Secret changes.

**Resolved in Phase 3, not deferred:** `app/db.py` mounts the
ESO-materialized Secret as a file (`charts/app/templates/deployment.yaml`)
and re-reads `username`/`password` from disk on every new database
connection, rather than once at import time. The `volumeMount` has no
`subPath` (a `subPath` mount is a bind-mount of a single file's content at
mount time and does **not** get kubelet's periodic refresh - one of the
most common ways this pattern silently breaks). Without `subPath`, kubelet
refreshes the projected Secret volume's file contents in place on its own
sync period (~60s) whenever the backing Secret object changes, and the
next connection `db.py` opens picks that up automatically. Residual
staleness is bounded by two numbers, both small: kubelet's ~60s volume
refresh, plus ESO's `refreshInterval: 1h` on the `ExternalSecret`
(`charts/app/templates/externalsecret.yaml`) for how often it re-fetches
from Secrets Manager in the first place.

**Reloader is no longer a dependency of this project.** It exists to solve
the env-var version of this problem (roll the Deployment on a Secret
change) - once credentials come from a re-read file instead, there's
nothing for a rolling restart to accomplish that the file refresh doesn't
already handle.

## `depends_on` and teardown ordering

Every `helm_release` in this module needs to not be destroyed after the EKS
API server becomes unreachable, or `terraform destroy` hits a 10-minute
timeout per release. This module can't express
"depends on `module.eks.aws_eks_node_group.default`" directly - that
resource lives in a sibling module, and cross-module resource references
aren't a thing `depends_on` can express from inside a child module.

Instead, `envs/staging/main.tf` sets `depends_on = [module.eks]` on the
`module "addons"` call itself. A module-level `depends_on` applies to
*every* resource inside that module symmetrically for both create and
destroy ordering - so every `helm_release`, `kubernetes_service_account`,
etc. in this module is created only after all of `module.eks` (nodegroup
included) exists, and destroyed only before any of `module.eks` is torn
down. That's a strictly stronger guarantee than depending on the nodegroup
alone, using the one form of cross-module ordering Terraform actually
supports here.
