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

### Verified: AmazonEKSEditPolicy does cover `secrets` - no RBAC gap for Helm release storage

`helm upgrade --install -n staging` writes its release state as a
`helm.sh/release.v1` Secret in the target namespace on every deploy. If
`ci_deploy`'s access policy didn't grant `secrets` in the core (`""`)
apiGroup, the workflow would fail on its very first Helm command - after
the image was already built and pushed under an immutable tag, the worst
place for it to fail.

**Checked directly against the raw HTML** of
`docs.aws.amazon.com/eks/latest/userguide/access-policy-permissions.html`
(`curl`, not the summarizing fetch tool - same page used for the
`external-secrets.io` finding, same verification discipline applied
again rather than trusted from memory). Two separate core-apiGroup rules
list `secrets` among their resources:

```
resources: pods/attach, pods/exec, pods/portforward, pods/proxy, secrets, services/proxy
verbs:     get, list, watch

resources: configmaps, events, persistentvolumeclaims, replicationcontrollers,
           replicationcontrollers/scale, secrets, serviceaccounts, services,
           services/proxy
verbs:     create, delete, deletecollection, patch, update
```

Combined, that's full CRUD on `secrets` - `create`, `delete`,
`deletecollection`, `get`, `list`, `patch`, `update`, `watch`. Sufficient
for Helm to create, read, and update its release Secret. **No change made**
to `ci_deploy_rbac.tf` or the access policy - this was a real risk worth
checking before the first live deploy, and it checks out. Consider this
verified; don't re-litigate it without new evidence.

### Fourth failure class: `sts:AssumeRoleWithWebIdentity` denied with a verified-correct trust policy - GitHub's immutable subject claims

`.github/workflows/deploy.yml`'s first live run failed at "Configure AWS
credentials via OIDC" with `Not authorized to perform
sts:AssumeRoleWithWebIdentity`, from STS - meaning a token was issued and
sent, and STS evaluated it against the trust policy and rejected it.

**Every AWS-side artifact checked out, one by one, before the real cause
was found:**

- Trust policy `sub`/`aud` conditions matched source exactly (compared
  against `terraform state show`, since live `aws iam get-role` reads were
  blocked by the permission system for most of this investigation).
- `Principal.Federated` matched the OIDC provider's real ARN.
- `client_id_list` (`["sts.amazonaws.com"]`) matched the requested `aud`.
- `var.github_org`/`var.github_repo` matched the actual GitHub repo's
  case-sensitive owner/name exactly (`gh repo view`) - no casing mismatch.
- No SCP possible - `aws organizations describe-organization` confirms
  this account isn't in an AWS Organization at all.
- No permissions boundary on `ci_deploy` (moot anyway - a boundary
  constrains what an assumed role can *do*, not whether it can be
  assumed).
- The OIDC provider's thumbprint, initially reported as "stale" in this
  log's working notes - **wrong, corrected before it was ever written up
  here.** `data.tls_certificate.github_actions.certificates[0]` returns
  the TLS chain **root-first** (the ISRG root CA), not leaf-first;
  comparing it against a freshly-`openssl`-fetched *leaf* certificate's
  fingerprint was comparing two different certificates in the chain, not
  the same certificate at two points in time. A fetch of the full 3-cert
  chain confirmed `certificates[0]`'s fingerprint exactly matches the
  root CA, and a fresh `terraform plan` showed zero drift on
  `thumbprint_list` - it was never stale. Pinning the root rather than
  the leaf is also the more correct choice: roots rotate far less often
  than the Let's Encrypt leaf here does (~90 days). Moot a second way too:
  AWS validates GitHub's cert chain against its own trusted root CA store
  for well-known providers, not the configured thumbprint value, per
  AWS's current documentation.

**With the AWS side exhausted, the actual cause was on GitHub's side, and
static analysis of the code couldn't find it - only querying GitHub's own
OIDC customization API did:**

```
gh api repos/Chethann-Raj/eks-platform/actions/oidc/customization/sub
{"use_default":true,"use_immutable_subject":false,"sub_claim_prefix":"repo:Chethann-Raj@148512002/eks-platform@1351373185"}
```

Not a clean 404 (which would have ruled out any custom subject-claim
handling entirely), and not a hand-configured `include_claim_keys`
template either (`use_default: true`, and that field is absent - per
GitHub's own docs, `include_claim_keys` is ignored when `use_default` is
true). What it revealed instead: **GitHub's immutable subject claims**
feature. Per GitHub's changelog, every repository created after
2026-07-15 automatically receives a second, ID-based `sub` claim format
alongside the legacy name-based one - no opt-in, no toggle required. This
repo was created 2026-08-30 (`gh api repos/.../eks-platform --jq
.created_at`), squarely inside that window; the numeric IDs in
`sub_claim_prefix` were independently confirmed against `gh api
users/Chethann-Raj` (id `148512002`) and the repo's own `id`
(`1351373185`) - not assumed from the prefix string alone.

The trust policy demanded exactly the legacy format
(`repo:Chethann-Raj/eks-platform:ref:refs/heads/main`). If GitHub sent the
immutable format instead
(`repo:Chethann-Raj@148512002/eks-platform@1351373185:ref:refs/heads/main`),
`StringEquals` fails to match, and STS returns precisely the generic
"not authorized" seen here - with nothing on the AWS side to point at,
because nothing on the AWS side was wrong.

**Fix:** `terraform/persistent/oidc.tf`'s `sub` condition on both
`ci_deploy_trust` and `ci_production_trust` now lists *both* prefix
formats (`local.github_sub_legacy_prefix`,
`local.github_sub_immutable_prefix`) for their respective suffixes
(`:ref:refs/heads/main`, `:environment:production`). `StringEquals`
against a list is an OR - both values identify the exact same repository
and branch/environment, so this is not a widening of trust, just accepting
two spellings of "this repo" until it's known which one GitHub actually
sends. `ci_production` needed the identical fix: its `sub` claim uses the
same `repo:<org>/<repo>` prefix (with an `:environment:` suffix instead of
`:ref:`), and the immutable-subject substitution applies to that prefix
regardless of what follows it. The two numeric IDs live in
`terraform/persistent/variables.tf` (`github_owner_id`, `github_repo_id`),
each commented with the exact `gh api` command that produces it - not
bare literals in `oidc.tf`.

**Debug step avoided entirely.** A temporary step to decode and print the
token's claims was prepared and verified working in isolation, but never
needed pushing - the GitHub OIDC customization API answered the question
directly, without touching a public repo's Actions logs at all.

**This trust policy is intentionally temporary in its current (dual-value)
form.** Once a real deploy run succeeds and CloudTrail's
`AssumeRoleWithWebIdentity` event confirms which `sub` value actually
matched, the condition should be narrowed back down to that one value -
carrying both indefinitely is unnecessary surface area once it's known
which format GitHub is really sending for this repo.

### First real deploy attempt (run 33335905391): two separate, real bugs in one rollback

OIDC fixed, image built and pushed
(`dc4c5e66cc3f71bdafbabf5ce3422b785551d164`), and the workflow still
failed - `--atomic` rolled everything back. The GitHub Actions log and
`kubectl get events` (read before the rollback tore the evidence down)
told two different, both-true stories, and conflating them would have
meant fixing the wrong thing first.

**Bug A - the actual reason the run's exit code was non-zero:**

```
Error: an error occurred while uninstalling the release. original install error:
externalsecrets.external-secrets.io is forbidden: User
"arn:aws:sts::<ACCOUNT_ID>:assumed-role/eks-platform-ci-deploy/GitHubActions"
cannot watch resource "externalsecrets" in API group "external-secrets.io"
in the namespace "staging"
```

`ci_deploy_rbac.tf`'s `Role` granted `create/get/list/patch/update/delete`
on `externalsecrets` but not `watch`. Helm 4's `--wait` uses a generic
kstatus-based waiter (from the `cli-utils` project) that watches *every*
resource a release creates to determine rollout status - custom resources
included, not a fixed list of built-in kinds. This wasn't visible from
reading the Role in isolation; only the actual failure surfaced it.
**Fix:** added `watch` to that Role's verb list.

**Bug B - observed via `kubectl get events`, absent from the CI log
entirely:**

```
FailedMount: secret "app-db-credentials" not found     (race - resolved; see below)
externalsecret/app-db-credentials: secret created
Pulled image ... Container started
Readiness probe failed: Get "http://10.0.11.143:8080/readyz": EOF
```

An EOF - connection accepted, closed with no response - not a 503 and not
a timeout, meant the worker process died handling the request rather than
`/readyz` returning a failure status. `/readyz`'s own DB check already had
a `try/except` returning 503 correctly - the crash had to be coming from
somewhere else. It was: `main.py`'s `@app.on_event("startup")` handler
(`_ensure_schema`) had **no error handling at all**. An uncaught exception
in an ASGI lifespan startup handler is fatal to uvicorn - the whole
process dies, not just that one operation - and a readiness probe that
then hits a dying/dead process gets a bare connection reset, not an HTTP
response. The likely trigger was the `FailedMount` race itself: if the
mounted Secret volume was still empty (or the mount not yet complete) at
the exact moment `_ensure_schema()` ran, `_read_credential()` raising
`FileNotFoundError` would have taken the whole process down.

**Could not get a literal traceback from the actual failing pod** -
`--atomic` deleted it before it could be inspected, and `kubectl logs`
can't retrieve output from a pod that no longer exists. Said so plainly
rather than fabricate one. A manual `helm upgrade --install` (no
`--atomic`, no `--wait`, exact `--set` values pulled from the run log, not
guessed) did not reproduce the crash - both pods came up `1/1 Running`
with `/readyz` returning `200` repeatedly from the first check onward.
Verified explicitly rather than assumed: mount path (`/etc/secrets/db`),
`db.py`'s read path, and the `ExternalSecret`'s `secretKey` names all
agree exactly; a throwaway `psql` pod in `staging` (deleted after) reached
RDS and got a real Postgres-protocol auth rejection (not a network
timeout), proving reachability from this namespace, not just from an
earlier ad-hoc pod in `default`.

**Fix:** moved the `CREATE TABLE IF NOT EXISTS` / seed-row logic into a
plain `_ensure_schema(conn)` function called from both places: the startup
handler now wraps it in `try/except` and only logs a warning on failure
(never raises), and `/readyz` calls the same function on every request
before its `SELECT 1` check, so schema setup self-heals the moment the DB
becomes reachable - no pod restart needed, and no code path left that can
take the process down on a DB hiccup. Verified locally (not just read) by
rebuilding the image and running it against a deliberately unreachable DB:
the process logged the exception and reached "Application startup
complete" instead of dying, `/healthz` returned `200`, `/readyz` returned
a clean `503` (not a dropped connection), and the container stayed up
through both requests. Then verified the happy path is unaffected against
a real throwaway Postgres: clean startup, `/readyz` `200`, `/` performing
a real read/write. This is the reconsideration asked for directly: a
readiness probe that kills the connection is strictly worse to operate
than one that answers honestly, and the fix is to remove every code path
that *can* kill the connection, not to add more guessing at the caller.

**The `FailedMount` race itself is confirmed observed, not hypothetical** -
it's in the events above, and it did resolve on its own (the `secret
created` event follows it). The Phase 3 decision to accept this via
kubelet's ordinary retry loop (Option B, no `helm.sh/hook` - see the
earlier "Secret mount race on first deploy" entry) held: the mount
eventually succeeded well within the deploy's timeout window. What Option
B's original write-up didn't anticipate was a *second* failure mode
stacked on top of it - an unrelated bug (Bug B above) turning a
successfully-resolved race into a process crash. The race resolving as
designed and the app surviving that resolution are two different
guarantees; Option B only ever provided the first one.

All manual diagnostic artifacts (the `helm install` done to reproduce
this, the throwaway `psql` pod, local Docker containers/network) were torn
down after use - nothing left running outside the CI/Terraform-managed
path.

### Fifth failure class: ExternalDNS's TXT ownership record silently never gets written at the zone apex

Run 33336673112 (Bugs A and B above, fixed) succeeded and deployed
cleanly. Separately, `https://chethanraj.site` was unreachable -
`curl`/`dig` returned nothing.

**Problem:** Route53's `chethanraj.site` A/AAAA alias pointed at an ALB
DNS name that no longer existed in the account - a different ALB
(`describe-load-balancers` confirmed only one, `active`, matching the
current Ingress) had replaced it at some point after ExternalDNS last
wrote the record. ExternalDNS (chart `1.21.1`, appVersion `0.21.0`,
`--policy=sync --registry=txt --txt-owner-id=eks-platform-staging`) was
running the whole time, on a 1-minute interval, and its logs repeated
`"All records are already up to date"` through every cycle - it never
attempted a fix.

**What was checked, in order:** the single `TargetGroupBinding` in the
cluster first (`serviceRef` resolved to the live `app` Service, and its
target group's `LoadBalancerArns` matched the current ALB - not an
orphan, ruled out immediately). Then IAM (`external_dns.tf`'s policy
grants `route53:ChangeResourceRecordSets`/`ListResourceRecordSets`
scoped to the one hosted zone, plus account-wide `ListHostedZones` -
correct, not the cause). Then `aws route53 list-resource-record-sets`
directly: **zero TXT records existed in the zone at all**, despite
`--registry=txt` being explicitly set - the real anomaly worth chasing.

**Root cause, confirmed by temporarily patching the Deployment to
`--log-level=debug`** (reverted after - the patch attempt to revert it
was itself blocked by the permission classifier as a live-cluster
mutation; left for the user, see below) and reading a full reconcile
cycle rather than guessing from INFO-level output alone:

```
Adding chethanraj.site. to zone chethanraj.site. [Id: /hostedzone/...]
Skipping record cname-chethanraj.site because no hosted zone matching record DNS Name was detected
Skipping record aaaa-chethanraj.site because no hosted zone matching record DNS Name was detected
```

ExternalDNS's default TXT-registry naming scheme builds the ownership
record's name by string-concatenating a type prefix directly onto the
DNS name (`"cname-" + "chethanraj.site"` -> `"cname-chethanraj.site"`).
For a subdomain like `app.example.com` this produces a valid subdomain
of the zone (`cname-app.example.com` still ends in `.example.com`). At
the **zone apex** - `chethanraj.site` has no subdomain label at all -
the same concatenation produces `cname-chethanraj.site`, which is a
*different* domain entirely under the `.site` TLD, not a subdomain of
`chethanraj.site`. ExternalDNS's own zone-matching correctly recognizes
this and skips writing the record - silently, at debug level only nothing
above that ever surfaces it. Debug output also showed the planner
correctly recomputing the desired ALB target every single cycle
(`Endpoints generated from ingress: ... 573505611 ...`) - it was never
blind to the change, it just could never prove ownership of the existing
record to justify updating it, and stayed stuck skipping it forever:
`"Skipping endpoint chethanraj.site ... A ... because owner id does not
match (found: \"\", required: \"eks-platform-staging\")"`.

Net effect: ExternalDNS can create the apex A/AAAA alias exactly once
(when nothing exists there yet, a genuine clean slate), but never
acquires TXT ownership over it, so on every later reconcile - including
after every nightly teardown/rebuild replaces the ALB - it treats its own
past record as foreign and refuses to correct it. This is a structural
bug for this project specifically because `chethanraj.site` is served at
the bare apex (`CLAUDE.md` §1/§6), not a subdomain, and the platform is
torn down and rebuilt nightly (§1), so the ALB's identity changes on
every rebuild.

**Immediate recovery (approved by the user, executed via `aws route53
change-resource-record-sets` - a live DNS mutation the permission
classifier correctly flagged for explicit confirmation first):** deleted
the two stale A/AAAA records. With the apex name+type clear, ExternalDNS's
very next cycle re-created them pointing at the correct, live ALB - `curl
https://chethanraj.site` returned `{"message":"Hello from
eks-platform","visits":1}` immediately after. This is a full, unavoidably
manual, out-of-band recovery step, not something the codebase itself
does - if the same ALB-replacement-while-DNS-is-unowned situation recurs
before the durable fix below is applied, it requires the same manual
delete again.

**Attempted fix, applied but UNVERIFIED:** added `txtPrefix = "txt."` to
`helm_release.external_dns`'s `set` block in
`terraform/modules/addons/external_dns.tf` and applied it. The theory: a
prefix ending in `.` forms a real subdomain when concatenated (`"txt." +
"chethanraj.site"` -> `"txt.chethanraj.site"`), which should correctly
zone-match and let ExternalDNS write and later recognize its own TXT
ownership record at the apex - restoring the update path this project's
cluster-name-based `txtOwnerId` (see the comment already in that file)
was designed to rely on for exactly this nightly-rebuild scenario.
`terraform fmt`, `terraform validate`, and `terraform plan` all ran clean
before applying - one resource changed, nothing else in the environment
drifted.

**It has not actually worked yet, as far as any evidence shows.** After
applying it: the stale apex A/AAAA were deleted to force a clean
create-cycle, and ExternalDNS did recreate them pointing at the live ALB
- but a direct, unfiltered `aws route53 list-resource-record-sets` dump
of the entire zone, checked three separate times across multiple
reconcile cycles (waiting a full cycle past the create each time), found
**zero TXT records of any name anywhere in the zone.** No ownership
record was produced.

One thing changed between the pre-fix and post-fix debug captures, and
it's suggestive but explicitly **not proof**: before the fix, every
cycle logged an explicit skip for the apex A/AAAA -
`"Skipping endpoint chethanraj.site ... A ... because owner id does not
match (found: \"\", required: \"eks-platform-staging\")"`. After the fix,
that line is simply gone - the only skip left in the debug output is for
the unrelated ACM DNS-validation CNAME record
(`_146318...chethanraj.site`), which was never ExternalDNS's to manage.
No line anywhere - write, skip, or otherwise - mentions a TXT record for
`chethanraj.site`, `txt.chethanraj.site`, or any other name during these
captures.

The problem with treating "the skip line disappeared" as confirmation:
every capture taken after the fix was a **steady-state** cycle, where the
live record already matched the desired target (because it had just been
manually recreated). `"All records are already up to date"` is true
regardless of whether TXT ownership tracking is actually functioning,
since there's nothing to reconcile either way when desired == actual.
The only way to see what ExternalDNS truly does with the TXT write is to
catch it live during an actual `CREATE` - a genuine mismatch between
desired and actual state - and no such event was observed after the
`txtPrefix` change was in place. The one real `CREATE` cycle captured
(`22:17:15Z`, `"Desired change: CREATE chethanraj.site A"` /
`"... AAAA"`) planned only the A and AAAA records - no TXT line appeared
there either, which is at best neutral and at worst evidence the write is
still silently failing under the new prefix, just via a different code
path that no longer happens to log a skip.

**This is deliberately left unresolved rather than force-verified.**
Forcing a real test means deleting the apex A/AAAA again and watching
the very next `CREATE` cycle with debug logging on - a second live DNS
mutation, right after the first one, purely to validate a hypothesis, and
not warranted this close to the submission deadline for a `staging`
environment that already has a working manual recovery path (below). The
honest status is: **`txtPrefix="txt."` is applied to the Terraform config
and currently live in the cluster, but whether it actually fixes TXT
ownership at the apex is unverified and will only be tested for real the
next time the ALB changes identity** - i.e., at the next teardown/
rebuild. If the site is unreachable after a rebuild with apex DNS
pointing at a dead ALB again, treat this fix as disproven and fall back
to the manual recovery procedure below.

## Runbooks

### Known issue: apex DNS after a rebuild

**Symptom:** `https://chethanraj.site` is unreachable. `dig +short
chethanraj.site` returns nothing (or resolves, but nothing answers on
443). The apex `A`/`AAAA` alias in Route53 points at an ALB DNS name
that no longer exists in the account.

**Cause, one line:** ExternalDNS's TXT ownership record for the apex
domain is missing (see "Fifth failure class" above), so it can create
the apex `A`/`AAAA` alias exactly once but never updates it again once
the ALB behind the Ingress is replaced - which happens on every
teardown/rebuild.

**Manual recovery.** Requires `aws` CLI configured with the `pro`
profile and `kubectl` pointed at the `staging` cluster. Nothing here
needs the AWS account ID - the zone ID and CLI profile are enough.

```bash
# 1. Confirm the symptom.
dig +short chethanraj.site
curl -sS -o /dev/null -w '%{http_code}\n' https://chethanraj.site || true

# 2. Look up the hosted zone ID without hardcoding it.
ZONE_ID=$(terraform -chdir=terraform/persistent output -raw hosted_zone_id)
echo "Zone ID: $ZONE_ID"

# 3. Find the ALB that's actually live behind the current Ingress.
LIVE_ALB_HOSTNAME=$(kubectl -n staging get ingress app \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Live ALB: $LIVE_ALB_HOSTNAME"

# 4. Pull the CURRENT apex A/AAAA records and their exact AliasTarget.
#    Route53 requires a DELETE request to match the existing record
#    byte-for-byte, so copy AliasTarget.HostedZoneId and DNSName
#    straight out of this output - do not retype them by hand.
aws route53 list-resource-record-sets --profile pro \
  --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Name=='chethanraj.site.' && (Type=='A' || Type=='AAAA')]" \
  --output json

# 5. If AliasTarget.DNSName above does NOT match $LIVE_ALB_HOSTNAME
#    (confirms staleness - optionally also check the old ALB is gone:
#    aws elbv2 describe-load-balancers --profile pro --query
#    "LoadBalancers[?DNSName=='<old DNSName from step 4>']" returns []),
#    build a DELETE change-batch using the exact AliasTarget from step 4.
#    Replace ALIAS_ZONE_ID and STALE_ALB_DNS_NAME below with those values.
cat > /tmp/delete-stale-dns.json <<'EOF'
{
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "chethanraj.site.",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "ALIAS_ZONE_ID",
          "DNSName": "STALE_ALB_DNS_NAME",
          "EvaluateTargetHealth": true
        }
      }
    },
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "chethanraj.site.",
        "Type": "AAAA",
        "AliasTarget": {
          "HostedZoneId": "ALIAS_ZONE_ID",
          "DNSName": "STALE_ALB_DNS_NAME",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
EOF
# Edit /tmp/delete-stale-dns.json now to fill in the two placeholders.

# 6. Submit the delete.
aws route53 change-resource-record-sets --profile pro \
  --hosted-zone-id "$ZONE_ID" \
  --change-batch file:///tmp/delete-stale-dns.json

# 7. Wait one ExternalDNS reconcile cycle (interval=1m; give it margin)
#    then confirm it recreated the records against the live ALB.
sleep 90
aws route53 list-resource-record-sets --profile pro \
  --hosted-zone-id "$ZONE_ID" \
  --query "ResourceRecordSets[?Name=='chethanraj.site.' && (Type=='A' || Type=='AAAA')].[Type,AliasTarget.DNSName]" \
  --output table
# Expect both rows' DNSName to equal $LIVE_ALB_HOSTNAME from step 3.

# 8. Verify externally.
dig +short chethanraj.site
curl -sS -o /dev/null -w '%{http_code}\n' https://chethanraj.site
# Expect: two IPs from dig, 200 from curl.
```

**This is a recovery procedure, not a fix.** It restores service for the
current ALB but does not resolve the underlying TXT-ownership gap - the
same failure will recur the next time the ALB is replaced, until "Fifth
failure class" above is confirmed resolved (or superseded by a different
fix).

## Phase 4 (observability + production deployment path)

### Loki CrashLoopBackOff: `singleBinary.persistence.enabled: false` does not fall back to an emptyDir

**Problem.** Added `helm_release.loki` (chart `grafana/loki` 7.3.0) to
`terraform/modules/addons/observability.tf`, following the same pattern
already used for `helm_release.kube_prometheus_stack`'s Prometheus:
disable persistence, assume the chart falls back to an emptyDir the way
prometheus-operator does when `storageSpec` is left unset. `terraform
apply` succeeded, but `helm_release.loki` itself failed with "context
deadline exceeded" after the full 10m timeout, and `atomic = true`
auto-uninstalled it - nothing was left in the cluster to inspect.

**What I tried.** Reproduced manually and deliberately without the
guardrails that had destroyed the evidence: `helm install loki
grafana/loki --version 7.3.0 -n monitoring -f <the same values Terraform
generated>`, no `--atomic`, no `--wait`, no `--timeout`, so a failing pod
would stay up. `loki-0` came up `1/2 Running` then went straight to
`CrashLoopBackOff`. `kubectl logs loki-0 -c loki --previous`:
```
mkdir /var/loki: read-only file system
error initialising module: ruler-storage
```
Not Pending (scheduled fine), not OOMKilled (`exitCode: 1, reason:
"Error"`, not 137), and no PVC was created (`persistence.enabled: false`
worked as intended on that front) - so the sizing, scheduling, and
WaitForFirstConsumer hypotheses were all ruled out before the actual cause
was found: the `loki` container runs with `readOnlyRootFilesystem: true`
(this chart's own hardened default), and its `volumeMounts` had nothing
mounted at `/var/loki` at all. Confirmed against the pinned chart's own
`templates/single-binary/statefulset.yaml`: the `storage`
volume+volumeMount at `/var/loki` only exists at all
`{{- if .Values.singleBinary.persistence.enabled }}`, as a PVC - there is
no chart-side emptyDir fallback the way prometheus-operator has one.
`ruler.enabled: true` is this chart's own default (never touched), and the
ruler module's WAL directory (`rulerConfig.wal.dir`, default
`/var/loki/ruler-wal`) tries to `mkdir` under `/var/loki` unconditionally
on startup - with nothing mounted there and a read-only root filesystem,
that `mkdir` fails and the process exits immediately.

**What fixed it.** Added `singleBinary.extraVolumes: [{name: storage,
emptyDir: {}}]` and `singleBinary.extraVolumeMounts: [{name: storage,
mountPath: /var/loki}]` alongside `persistence.enabled: false` (still no
PVC). Also added `ruler.enabled: false` (no alerting rules are configured
and Alertmanager is already cut) - noted in the Terraform comment that
this alone does not fix the crash, since the compactor and the
index/chunk WAL also write under `/var/loki` regardless of the ruler.
Verified with `helm template ... | grep -A5 /var/loki` before committing
to the shape (a rendered `emptyDir`, not a PVC, mounted at `/var/loki`),
then re-installed manually the same no-atomic/no-wait way: `loki-0` reached
`2/2 Running` in 47s with zero restarts, `/ready` returned `200 ready`.

Also changed `helm_release.loki`'s `atomic` to `false` (every other release
in this module keeps `atomic = true`) - a failed install should stay up
for `kubectl describe`/`logs` to actually diagnose it, not get
auto-rolled-back before anyone can look, which is exactly what cost the
first 10 minutes here.

### Copy-paste bugs in `terraform/envs/production/` - never previously applied, caught before any apply

`terraform/envs/production/` was scaffolded from `terraform/envs/staging/`
and had two live bugs, found while wiring the CI/CD production deployment
job:

1. **`variables.tf`'s `environment` variable defaulted to `"staging"`**,
   not `"production"`. `terraform.tfvars` (gitignored, not committed)
   happens to override this correctly today - confirmed via `terraform
   console` that `local.cluster_name` resolves to
   `"eks-platform-production"` - but the *default* was a live landmine: a
   fresh clone running `terraform plan` in this directory with no
   `terraform.tfvars` present would have silently planned a second
   `"eks-platform-staging"`-named environment instead of failing loudly,
   colliding with the real one. Fixed the default to `"production"`, and
   added `terraform.tfvars.example` to both `envs/staging` and
   `envs/production` so a fresh clone has an explicit file to copy from
   instead of relying on defaults being correct.

2. **`main.tf`'s `access_entries.ci_deploy` block referenced the wrong
   role and the wrong namespace** - `principal_arn =
   data.terraform_remote_state.persistent.outputs.ci_deploy_role_arn`
   (staging's CI role, trusted only for `sub:
   repo:.../...:ref:refs/heads/main`) scoped to `namespaces = ["staging"]`,
   inside what is supposed to be the *production* cluster. The role that
   actually exists for production is `aws_iam_role.ci_production`
   (`terraform/persistent/oidc.tf`, output `ci_production_role_arn`,
   trusted only for `sub: repo:.../...:environment:production`). Fixed to
   reference `ci_production_role_arn`, scoped to `namespaces =
   ["production"]`, and renamed the map key (`ci_deploy` → `ci_production`)
   and the local group variable (`ci_deploy_k8s_group` →
   `ci_production_k8s_group`, value `"${var.project}-ci-production"`) to
   match - production had never been applied, so renaming the `for_each`
   map key here is not a destroy/recreate.

**Not fixed, flagged instead - genuinely out of scope for this pass:**
- `terraform/modules/addons` (`staging_namespace.tf`,
  `ci_deploy_rbac.tf`) hardcodes the namespace name `"staging"` - it is
  not parameterized by environment. `module.addons` in
  `envs/production/main.tf` will therefore still try to create a
  namespace literally named `"staging"` inside the production cluster, and
  bind its supplementary RBAC Role there, not into a `"production"`
  namespace - even after the access-entry fix above. The EKS access entry
  now correctly grants `ci_production` edit access scoped to a
  `"production"` namespace that nothing currently creates. This needs a
  `namespace` variable added to `modules/addons` (and both env callers
  updated) before `module.addons` can actually be applied against
  production.
- `module.rds` in `envs/production/main.tf` still carries the same
  `deletion_protection = false`, `skip_final_snapshot = true`,
  `backup_retention_period = 0` overrides as staging, commented "staging
  only, nightly teardown" - but production is not torn down nightly. As
  written, a production RDS instance would have zero backup retention and
  no deletion protection. This is a real data-loss risk if ever applied
  as-is, but changing production's durability posture wasn't part of this
  pass and deserves an explicit decision, not a silent edit.
- `aws_iam_role.ci_production` (`terraform/persistent/oidc.tf`) has "no
  permission policy attached yet" (its own comment) - it can authenticate
  via OIDC but cannot yet call `ecr:GetAuthorizationToken`,
  `eks:DescribeCluster`, or anything else the production CI job needs.
  `.github/workflows/deploy.yml`'s new `production` job is gated behind
  `vars.PRODUCTION_ENABLED` (deliberately unset) specifically so it stays
  dormant until this and the two points above are resolved.
