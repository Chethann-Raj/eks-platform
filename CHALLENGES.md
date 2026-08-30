# Challenges log

Running log per CLAUDE.md §2 — problem, what was tried, what fixed it. Not
cleaned up until Phase 5.

---

## Phase 1

### Local Terraform binary was 1.5.0, below the 1.11 floor

**Problem:** CLAUDE.md requires Terraform >= 1.11 (needed for stable
`use_lockfile` support on the S3 backend). The installed binary
(`/opt/homebrew/bin/terraform`) was 1.5.0.

**What I tried:** Checked for a version manager already on the machine
(`tfenv`) rather than reinstalling over the Homebrew binary.

**Fix:** `tfenv` was already installed. Ran `tfenv install 1.13.5 && tfenv use
1.13.5` — a local tooling change only, no AWS resources touched. `terraform
version` now reports 1.13.5, which satisfies both the `>= 1.11` floor and
`use_lockfile`.

### AWS provider version pin

Initially pinned `~> 5.82` (two-part constraint), which actually floats
across every 5.x release up to (but not including) 6.0 — that's not really a
pin, it's a loose floor. Tightened to `~> 5.82.0` (three-part) so
`terraform init` locks to the 5.82.x patch line only, per the "no floating
latest" rule in CLAUDE.md §2. Locked at 5.82.2 in `.terraform.lock.hcl`.

### State bucket name could not be account-ID-derived

**Problem:** The original bucket name interpolated
`data.aws_caller_identity.current.account_id` to guarantee global uniqueness.
But `backend "s3" {}` blocks cannot reference variables or data sources — the
bucket name has to appear as a literal string in `persistent/backend.tf` and
`envs/staging/backend.tf`. Since this repo is public, that would mean
committing the AWS account ID in plaintext to git history, permanently.

**Fix:** Renamed the bucket to `chethanraj-${var.project}-tfstate` (i.e.
`chethanraj-eks-platform-tfstate`), unique via a personal prefix instead of
the account ID. `data.aws_caller_identity.current` is kept in the module and
now only feeds an `AccountId` resource tag for traceability, never the name.
Left an explicit "do not improve this back" comment in `main.tf` next to the
bucket name so a future pass doesn't reintroduce the leak in the name of
tidiness.

### AWS provider bumped to v6 mid-build

**Decision:** Moved from `~> 5.82.0` to `~> 6.62.0`. v5 is security-fix-only
as of v6's June 2025 GA, so starting a new build on v5 would mean adopting a
provider line with a known end date. Deliberately avoided `6.57.0`, which was
pulled from the registry.

Checked the official v6 upgrade guide (`terraform-provider-aws` repo, since
the rendered registry page is a JS SPA that doesn't fetch as plain text)
before assuming safety. The only S3-relevant change in v6 is `aws_s3_bucket`
repurposing its `region` attribute for Enhanced Region Support in favor of a
new `bucket_region` attribute — this module never reads `.region` off the
bucket resource, so it's unaffected. None of
`aws_s3_bucket_versioning`/`_server_side_encryption_configuration`/`_public_access_block`/`_lifecycle_configuration`/`_policy`
changed, and the provider-block-level removals (`endpoints.opsworks` /
`simpledb` / `sdb` / `worklink`) don't apply since this module's provider
block doesn't set any of them.

## Phase 1 (EKS module)

### EKS cluster role had no KMS permissions for secrets encryption

**Problem:** `aws_eks_cluster.this` sets `encryption_config` for envelope
encryption of Kubernetes Secrets, pointing at a customer-managed KMS key.
`AmazonEKSClusterPolicy` (attached to the cluster's IAM role) grants no KMS
actions at all, and a `aws_kms_key` created with no explicit `policy`
argument gets only the AWS default key policy (delegates to the account's
IAM policies, but grants nothing to this role specifically). Without an
identity-based policy on the cluster role, cluster creation with
`encryption_config` set fails - EKS can't get the grants it needs to
actually use the key.

**Fix:** Added `aws_iam_role_policy.cluster_kms` on `aws_iam_role.cluster`,
scoped to the one key ARN (`var.kms_key_arn`), granting exactly
`kms:Encrypt`, `kms:Decrypt`, `kms:DescribeKey`, `kms:CreateGrant`,
`kms:ListGrants` - matching AWS's own documented minimum for EKS secrets
encryption (`DescribeKey`, `CreateGrant`, `Decrypt`) plus `Encrypt` and
`ListGrants` for completeness. Added to `aws_eks_cluster.this`'s
`depends_on` so the policy exists before cluster creation attempts to use
the key.

### KMS key for EKS secrets encryption moved out of the eks module

**Problem:** The key and its alias were originally created inside
`terraform/modules/eks/`, which gets instantiated by `envs/staging` -
destroyed and rebuilt nightly. Scheduling a KMS key for deletion (which is
what `terraform destroy` does to a `aws_kms_key`, not immediate deletion)
keeps its alias allocated for the entire `deletion_window_in_days` window.
That means: (1) the next night's `terraform apply` fails trying to recreate
the same `alias/...` name, since the pending-deletion key still owns it, and
(2) every nightly teardown/rebuild cycle leaves another billable key stuck
in `PendingDeletion` behind it, accumulating indefinitely.

**Fix:** Moved `aws_kms_key.eks`/`aws_kms_alias.eks` into
`terraform/persistent/kms.tf` (built once, never destroyed nightly - see
CLAUDE.md §6). The eks module now takes the key's ARN as
`var.kms_key_arn`, an input it does not create. Documented the
irreversibility of this key's deletion in `terraform/persistent/README.md`
- once a live cluster references it for secrets encryption, scheduling
deletion permanently breaks decryption of every Secret encrypted with it.

### Two apply-time-only failures on the first real `apply`

Both of these are the same class of problem: `terraform validate` (and even
`terraform plan`) saw nothing wrong - the string/number was a syntactically
valid value of the right type - and the failure only surfaced against the
real AWS API, minutes into `apply`. Static validation can't catch either
one; only checking against AWS itself (`aws eks list-access-policies`,
`aws ec2 describe-instance-type-offerings`, or just attempting the apply)
does.

**Problem 1 - EKS access policy ARNs are a separate namespace from IAM
policy ARNs.** `aws_eks_access_policy_association.this` was built with
`policy_arn = each.value.policy_arn`, and the caller
(`envs/staging/main.tf`) supplied
`arn:aws:iam::aws:policy/AmazonEKSClusterAdminPolicy` /
`.../AmazonEKSEditPolicy` - real, existing IAM policy ARNs, but the wrong
namespace entirely. `apply` failed with `InvalidParameterException: The
policyArn parameter format is not valid`. EKS cluster access policies live
under `arn:aws:eks::aws:cluster-access-policy/<name>`, confirmed against
the account with `aws eks list-access-policies --region ap-south-1
--profile pro` rather than guessed.

**Fix:** Changed `var.access_entries` in `modules/eks/variables.tf` to take
`access_policy` (a bare name, e.g. `"AmazonEKSClusterAdminPolicy"`) instead
of `policy_arn`. `modules/eks/access_entries.tf` now builds the ARN itself:
`policy_arn = "arn:aws:eks::aws:cluster-access-policy/${each.value.access_policy}"`,
with a comment on that line spelling out that this is a distinct ARN
namespace from IAM and that `terraform validate` cannot catch a wrong
prefix here. Updated `envs/staging/main.tf` to pass
`"AmazonEKSClusterAdminPolicy"` / `"AmazonEKSEditPolicy"` as names. Scope
behavior unchanged: `admin` stays cluster-scoped, `ci_deploy` stays
namespace-scoped to `staging`.

**Problem 2 - the AWS account's Free Tier plan blocks non-free-tier EC2
instance types, account-wide.** Nodegroup creation failed after 33 minutes
(the nodegroup waiter runs to its own timeout before surfacing anything) with
`AsgInstanceLaunchFailures: Could not launch Spot Instances.
InvalidParameterCombination - The specified instance type is not eligible
for Free Tier.` This is an account-plan restriction, not a quota problem -
it doesn't show up as a quota error anywhere, and the 16/32 vCPU quotas
recorded in `CLAUDE.md` §5 are irrelevant to it. None of
`t3.large`/`t3a.large`/`m6i.large`/`m5.large` (the original
`node_instance_types` default) are Free Tier-eligible in this account.

Free-tier-eligible types in `ap-south-1`: `t4g.micro`, `t4g.small`,
`t3.micro`, `t3.small`, `m7i-flex.large`, `c7i-flex.large`. Only the two
`*-flex.large` types are viable EKS nodes - the micro/small types cap out
at roughly 11 pods under the VPC CNI's ENI-based pod density limit, and
CoreDNS + kube-proxy + aws-node alone consume most of that before any
workload pod lands.

**Fix:** Changed `node_instance_types` default in `modules/eks/variables.tf`
to `["m7i-flex.large", "c7i-flex.large"]`, `capacity_type` unchanged
(`SPOT`), `ami_type` unchanged (`AL2023_x86_64_STANDARD` - both flex types
are x86_64). Verified AZ coverage rather than trusting the assumption:
`aws ec2 describe-instance-type-offerings` confirmed both types are offered
in `ap-south-1a` and `ap-south-1b`, where the private subnets actually are.
Comment on `node_instance_types` records that the list is constrained by
the account's Free Tier plan (not preference, not vCPU quota), that this
drops the Spot capacity pool count from 4 to 2, and that flex instances
throttle CPU above their baseline - accepted for staging, flagged as a
scale-up consideration.

The failed nodegroup (`eks-platform-staging-default`, `CREATE_FAILED`) was
already present in Terraform state when checked - `apply` had gotten far
enough to record it before the async waiter timed out, so there was no
state-absent/AWS-present orphan or naming collision risk going into the
fix. Changing `instance_types` forces its replacement on the next `apply`.

## Phase 2 (addons module)

### Third failure class: in-cluster admission ordering between two independently-installed Helm charts

This one is distinct from both Phase 1 entries above, and worth naming as
its own category: `terraform fmt`, `terraform validate`, and
`terraform plan` all passed, and the `apply` itself was correct - every
resource applied as planned. The failure was **in-cluster**, in Kubernetes
admission control, between two Helm releases Terraform applied in parallel
because nothing in the Terraform config told it not to. Terraform's
dependency graph has no visibility into what a chart's templates create or
what webhooks they register - that information doesn't exist anywhere
Terraform can see it, only inside the chart itself.

**Problem:** All three `helm_release` resources ran in parallel. The AWS
Load Balancer Controller chart installs a cluster-wide
`MutatingWebhookConfiguration` on Services (`mservice.elbv2.k8s.aws`,
`failurePolicy: Fail`) as soon as its own resources are created - before
its pods are actually serving on `:9443`. The `external-secrets` chart
creates Services as part of its own install. `external-secrets` hit that
webhook during the roughly 28-second window where the webhook
configuration existed but had no ready endpoints behind it, and failed
admission:

```
Internal error occurred: failed calling webhook "mservice.elbv2.k8s.aws":
no endpoints available for service "aws-load-balancer-webhook-service"
```

LBC and ExternalDNS both installed cleanly. `external-secrets` was left in
Helm's `failed` state, which had to be `helm uninstall`ed by hand before
Terraform could attempt that release again - its namespace and service
account (Terraform-owned) survived the uninstall; contrary to what was
initially assumed, verification (`kubectl get crd | grep
external-secrets.io`) found **zero** external-secrets CRDs on the cluster,
not leftover ones - the release evidently failed before Helm applied them.

**This is non-deterministic.** A slightly slower `external-secrets` chart
pull, or a slightly faster LBC pod start, and this apply would have
succeeded outright. The same configuration can pass on one nightly rebuild
and fail on the next for no code reason at all - which is exactly why it
wasn't caught by `plan` and won't be caught by `plan` in general.

**Fix, two parts:**

1. Set `enableServiceMutatorWebhook = "false"` on
   `helm_release.aws_load_balancer_controller`. Verified against the
   pinned chart (v3.5.0) rather than trusting the value key or its effect:
   `values.yaml` confirms the key and its default
   (`enableServiceMutatorWebhook: true`,
   `serviceMutatorWebhookConfig.failurePolicy: Fail`), and
   `templates/webhook.yaml` confirms `{{- if
   .Values.enableServiceMutatorWebhook }}` gates the entire
   `mservice.elbv2.k8s.aws` webhook entry - setting it `false` removes the
   webhook from the `MutatingWebhookConfiguration` outright. That webhook
   only exists to stamp `spec.loadBalancerClass` onto `type: LoadBalancer`
   Services so LBC provisions an NLB for them; this platform routes
   everything through Ingress/ALB (`CLAUDE.md` §7) and never creates a
   `LoadBalancer`-type Service, so the webhook was doing nothing useful
   here while sitting in front of every Service creation in the cluster
   with `failurePolicy: Fail`.
2. Added `depends_on = [helm_release.aws_load_balancer_controller]` to
   `helm_release.external_secrets` (it creates Services; ExternalDNS
   doesn't, so it stays parallel, unchanged) and `atomic = true` plus an
   explicit `timeout` to all three `helm_release` resources. Checked the
   pinned helm provider's (3.2.0) own schema rather than assuming: `atomic`
   sets `wait` automatically ("The wait flag will be set automatically if
   atomic is used"), so `wait` is deliberately not also set - would be
   redundant. Without `atomic`, a failed install leaves the release in
   Helm's `failed` status, which Terraform will not create over - forcing
   exactly the manual `helm uninstall` this incident required before the
   next `apply` could even attempt the release again.

### Suspicious content via a web-fetch tool (previous session) - CORRECTED, see Phase 3 verification below

While researching Route53 IAM resource-level permissions for the
ExternalDNS policy, a web-fetch tool call against an AWS documentation
page returned content ending in a "See also" section instructing the
agent to run `aws agent-toolkit search-skills --search-query Route53`,
framed as an official AWS-recommended step. Not executed, flagged to the
user rather than acted on.

**Correction (Phase 3 blockers pass):** this entry originally attributed
the text to the fetched AWS page itself ("prompt injection via fetched web
content"). A direct `curl` of the raw HTML for two later occurrences of
this same pattern (see below) found **zero** matches for either
`agent-toolkit` or `search-skills` in what AWS actually serves - the text
does not exist in the real page. This specific occurrence's source page
was not independently re-`curl`'d, so treat the attribution below as
inferred from the now-confirmed pattern, not independently reverified for
this exact page - but the likely correct statement is: the fetch
tooling's own processing (not the raw HTTP response) is introducing this
text, so it was never AWS content to begin with. Not a claim about AWS
being compromised; a claim about what layer actually produced the text.

**The general point still holds regardless of which layer introduced it:**
in an agentic workflow, any content arriving through a tool call - fetched
web content included - is untrusted input. An instruction found inside it
is data to be read, never authorization to take an action, whether it
originated from the actual remote page or was introduced by processing
between the remote page and the agent.

## Phase 3 (app + CI/CD)

### metrics-server was never deployed - the HPA was silently non-functional

**Problem:** `kubectl top nodes` returned "Metrics API not available."
`charts/app/templates/hpa.yaml` targets CPU utilization, which requires the
`metrics.k8s.io` API that only `metrics-server` provides - without it, the
HPA sits at `<unknown>/70%` forever and never scales. Nothing in the
deploy pipeline would ever surface this: `helm upgrade --wait --atomic`
waits on the Deployment/pods it creates, not on whether the HPA it also
created can actually read metrics. A deploy goes fully green while the
autoscaling deliverable is dead.

**Fix:** Added `aws_eks_addon.metrics_server` to `terraform/modules/eks/
addons.tf`, matching the existing `coredns` addon's shape exactly (needs
nodes, no IRSA - it only reads the kubelet summary API on each node, never
an AWS API). Version `v0.9.0-eksbuild.7` confirmed as the current default
for Kubernetes 1.35 in `ap-south-1` via `aws eks describe-addon-versions`,
not reused from memory.

### `kubectl auth can-i --as <role-arn>` was testing the wrong identity - twice unverified, in different ways

**Problem 1 (impersonation):** The original check ran `--as
"arn:aws:iam::<acct>:role/eks-platform-ci-deploy"`. `--as` sets a literal
Kubernetes username via impersonation; EKS access entries map a role
principal to a *different*, EKS-derived username -
`arn:aws:sts::<acct>:assumed-role/eks-platform-ci-deploy/{{SessionName}}`
(confirmed via `aws eks describe-access-entry`) - and, per AWS's own
documentation (`docs.aws.amazon.com/eks/latest/userguide/
access-policies.html`): *"If you impersonate a Kubernetes user or group...
you're forcing the use of Kubernetes RBAC authorization. As a result, the
IAM principal has no permissions assigned by any access policies
associated to the access entry."* The impersonated string has zero
bindings of any kind, so the check returned "no" regardless of what's
actually granted - a structurally meaningless result, not evidence of a
deny.

**What should have been done instead, in order of preference:**

- **(a) Static facts first, no live check needed:** `aws eks
  list-access-entries` + `describe-access-entry` for the `ci_deploy`
  principal - gets the exact derived `username` and confirms
  `AmazonEKSEditPolicy` is associated with `accessScope: {type: namespace,
  namespaces: [staging]}`.
- **(b) Test as the real identity:** `aws sts assume-role
  --role-arn <ci_deploy arn> --role-session-name rbac-check --profile pro`
  from `terraform-admin`, then run the `can-i` checks under those real
  temporary credentials (no `--as`). **This failed as expected** -
  `ci_deploy`'s trust policy is GitHub OIDC only
  (`terraform/persistent/oidc.tf`), so `terraform-admin` gets
  `AccessDenied` on `sts:AssumeRole`. Confirmed, not worked around.
- **(c) Decode the grant statically instead:** fetched AWS's own published
  permission table for `AmazonEKSEditPolicy`
  (`docs.aws.amazon.com/eks/latest/userguide/access-policy-permissions.html`)
  - the complete, authoritative rule list, not the
  `rbac.authorization.k8s.io/aggregate-to-edit`-labeled
  `external-secrets-edit` ClusterRole (a different object entirely: that
  label aggregates into Kubernetes' own built-in `edit` ClusterRole, which
  has nothing to do with what AWS's `AmazonEKSEditPolicy` access policy
  itself grants).

**Problem 2 (the actual answer, and a second issue it exposed):**
`AmazonEKSEditPolicy`'s complete rule list (apiGroups `apps`,
`autoscaling`, `batch`, `discovery.k8s.io`, `extensions`,
`networking.k8s.io`, `policy`, and core) does **not** include
`external-secrets.io` anywhere, and has no wildcard apiGroup rule. So
`ci_deploy` genuinely cannot create the `ExternalSecret` in `charts/app/`
via the access policy alone - the original "no" was the right eventual
answer, arrived at for the wrong reason. Fixing this exposed a second,
independent issue: the natural fix is a namespaced `Role`/`RoleBinding`
bound to `ci_deploy`'s identity - but that identity's EKS-derived
`username` is a *template* containing the literal substring
`{{SessionName}}`, substituted with the real per-invocation session name
only at authentication time. A `RoleBinding` subject requires an exact
string match, so binding to that literal templated string would never
match any real GitHub Actions run (each picks its own session name).

**Fix:** Added `kubernetes_groups = ["eks-platform-ci-deploy"]` to the
`ci_deploy` access entry (`modules/eks/access_entries.tf`/`variables.tf`) -
confirmed via `aws eks create-access-entry help` that `--kubernetes-groups`
is documented as exactly "the value for name that you've specified for
`kind: Group`... in a Kubernetes RoleBinding," with no per-session
variability. Added a namespaced `Role` + `RoleBinding` in
`terraform/modules/addons/ci_deploy_rbac.tf`, scoped to `create`/`get`/
`list`/`patch`/`update`/`delete` on `externalsecrets.external-secrets.io`
in the `staging` namespace only, bound to that stable group name - nothing
cluster-scoped, no second access policy association.

### Secret mount race on first deploy - chose no hook (Option B)

**Problem:** `charts/app/` creates the `ExternalSecret` and the `Deployment`
in the same Helm pass. The Deployment mounts a Secret that doesn't exist
until ESO reconciles the `ExternalSecret`, so pods can briefly sit in
`ContainerCreating` on a missing volume - the same class of race that
caused the Phase 2 `external-secrets` install failure, though here it's
self-resolving rather than admission-rejecting.

**Decision: Option B - no hook, accept the kubelet retry loop.** Considered
Option A (`helm.sh/hook: pre-install,pre-upgrade` with `hook-weight: -5`
and `hook-delete-policy: before-hook-creation` on the `ExternalSecret`),
which is deterministic but has a real, stated cost: hook resources aren't
tracked in the release manifest, so `helm uninstall` would orphan the
`ExternalSecret`. That cost is a bad trade here for a small, bounded
upside: kubelet's mount-retry backoff is standard, well-understood
behavior (not a hard failure - `FailedMount` events, periodic resync,
resolves the moment the Secret appears), ESO reconciles a *new*
`ExternalSecret` almost immediately rather than waiting for its 1h
`refreshInterval` (which only governs re-fetching an already-synced one),
and `.github/workflows/deploy.yml` already runs `helm upgrade --install
--wait --atomic --timeout 5m` regardless - the exact safety net a race
like this needs. Trading a Helm-lifecycle footgun (orphaned resources
surviving `helm uninstall`, which cuts against this project's general
carefulness about orphaned resources - `CLAUDE.md` §10) for closing a race
that already resolves within an existing timeout wasn't worth it.

### The rotation question, closed

`app/db.py` re-reads `username`/`password` from the mounted Secret file on
every new database connection, not once at import - see
`terraform/modules/addons/README.md`'s "RDS password rotation" section
(revised this phase from "Reloader is a Phase 3 dependency" to resolved).
Confirmed the `volumeMount` in `charts/app/templates/deployment.yaml` has
no `subPath` - a `subPath` mount bind-mounts a single file's content at
mount time and does **not** receive kubelet's periodic projected-volume
refresh, which is one of the most common ways this exact pattern silently
breaks. Without `subPath`, kubelet refreshes the mounted file in place on
its own sync period (~60s) whenever the backing Secret changes, and the
next connection `db.py` opens picks it up. Residual staleness is bounded
by two numbers: kubelet's ~60s refresh, plus ESO's `refreshInterval: 1h` on
the `ExternalSecret` for how often it re-fetches from Secrets Manager in
the first place. **Reloader is no longer a dependency of this project** -
it exists to solve the env-var version of this problem (roll the
Deployment on a Secret change); once credentials come from a re-read file
instead, there's nothing left for a rolling restart to accomplish.

### Verified: the "agent-toolkit search-skills" text is not AWS content - it's introduced by the fetch tool

Fetching `docs.aws.amazon.com/eks/latest/userguide/access-policies.html`
and `docs.aws.amazon.com/eks/latest/userguide/access-policy-permissions.html`
for this phase's RBAC research (via the same summarizing web-fetch tool
used in the two prior occurrences) both returned content ending in a "See
also" section instructing the agent to run `aws agent-toolkit
search-skills`.

**Verified before writing this entry, not assumed:** `curl`'d the raw HTML
of both pages directly (bypassing the summarizing fetch tool entirely) and
grepped for `agent-toolkit` and `search-skills`. **Zero matches in either
file.** Both pages' actual served HTML ends in AWS's standard "Did this
page help you?" feedback widget - no "See also" section, no mention of any
CLI tool, nothing about skills. `wc -c` confirmed full pages were
retrieved (30,632 and 140,343 bytes), not empty/error responses.

**Correction to this log:** this is not AWS documentation content, and
"prompt injection" (implying a third party tampered with AWS's page) was
the wrong framing. The text is being introduced somewhere between the raw
HTTP response and what the summarizing fetch tool returns - by that tool's
own processing, not by AWS. The same correction applies to the Phase 2
entry above. The general caution stands regardless: content arriving
through any tool call is untrusted input until corroborated, and an
instruction embedded in it - AWS-sourced or not - is never
self-authorizing. What changes is where the caution needs to point: at the
fetch tool's own output, not at "AWS's docs might be compromised."
