# eks-platform

I built this as a portfolio deliverable: a production-shaped AWS EKS platform
running a FastAPI app backed by RDS Postgres, fronted by an ALB with TLS,
deployed through GitHub Actions, and monitored with Prometheus, Grafana and
Loki. The staging environment is destroyed every night to control cost and
rebuilt on demand, so everything here comes from `terraform apply` with no
manual console steps.

The live site is https://chethanraj.site. It serves a server-rendered landing
page that reads and writes a visit counter in Postgres on every load, so a
200 response is a real end-to-end check, not a static page.

## Prerequisites and setup

I needed the AWS CLI authenticated as an IAM user called `terraform-admin`
under a profile named `pro`, Terraform 1.11 or newer, `kubectl`, and `helm`.
The domain `chethanraj.site` was already registered at Namecheap before any
of this started.

Clone the repo and bootstrap the state bucket first. This is the one layer
that uses local state, because the S3 bucket it creates doesn't exist yet
for anything else to point at:

```bash
git clone https://github.com/Chethann-Raj/eks-platform.git
cd eks-platform/terraform/bootstrap
terraform init
terraform providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform plan
terraform apply
```

That creates `chethanraj-eks-platform-tfstate`, the S3 bucket every other
layer's `backend "s3" {}` block points at by literal name (backend blocks
can't interpolate variables, so the name is hardcoded the same way in every
layer).

Next, the persistent layer: the Route53 zone, the wildcard ACM certificate,
the ECR repository, and the GitHub OIDC provider and its two IAM roles.

```bash
cd ../persistent
cp terraform.tfvars.example terraform.tfvars   # if not already present
terraform init
terraform plan
terraform apply
```

`aws_acm_certificate_validation.wildcard` blocks inside that apply until ACM
can resolve the DNS validation records against the zone. That requires
Namecheap delegation to have propagated first, so between creating the zone
and finishing this apply I had to go into the Namecheap dashboard, under
Domain List, chethanraj.site, Manage, Nameservers, Custom DNS, and enter the
four `*.awsdns-*` nameservers that `terraform output hosted_zone_name_servers`
printed. I confirmed propagation with `dig +short NS chethanraj.site` before
re-running apply.

On the first apply of any environment that creates an EKS cluster, I hit a
DNS failure I want to flag here rather than let someone else lose an hour to
it. `modules/eks/oidc.tf` fetches the cluster's OIDC issuer certificate
(`data.tls_certificate.eks`, resolving `oidc.eks.ap-south-1.amazonaws.com`)
right after the cluster comes up, so it can register that issuer with IAM
for IRSA. On my Mac this SERVFAILed under the default resolver. Re-running
with Go's pure-Go DNS resolver forced on worked:

```bash
GODEBUG=netdns=go terraform apply
```

Then staging:

```bash
cd ../envs/staging
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
aws eks update-kubeconfig --name eks-platform-staging --region ap-south-1 --profile pro
```

`terraform.tfvars.example` in both `envs/staging` and `envs/production` lists
every variable the environment accepts, even though all of them already have
defaults in `variables.tf`. `terraform.tfvars` itself is gitignored, so a
fresh clone had nothing to look at before I added the example files.

Once the cluster answers, `helm upgrade --install app charts/app` from
`.github/workflows/deploy.yml` is what actually puts the application on it,
not a manual step here. Pushing to `main` triggers that.

Before any real teardown, `scripts/pre-destroy.sh` has to run first. It
deletes every Ingress and PVC in the cluster so the AWS Load Balancer
Controller releases its ALBs and ExternalDNS records, and the EBS CSI driver
releases its volumes, before Terraform destroys the cluster out from under
them. `scripts/survivor-sweep.sh` checks afterward that no EKS cluster, RDS
instance, NAT gateway, load balancer, unattached EBS volume, or unassociated
Elastic IP is left behind.

## Architecture

I built the VPC (`terraform/modules/vpc`) with a `10.0.0.0/16` CIDR across
two availability zones, sorted deterministically so the AZ that got the NAT
gateway wouldn't change between plans. I put public subnets at `10.0.0.0/24`
and `10.0.1.0/24`, tagged `kubernetes.io/role/elb=1` for the ALB, and
private subnets at `10.0.10.0/24` and `10.0.11.0/24`, tagged
`kubernetes.io/role/internal-elb=1`, where the EKS nodes and the RDS
instance both live. I gave it one NAT gateway instead of one per AZ, which
saved about $32 a month at the cost of an AZ-level single point of failure
for egress from the private subnets. I also added a gateway VPC endpoint
for S3, attached to every route table, so ECR image layer pulls and Loki's
filesystem writes wouldn't get billed as NAT data processing. VPC Flow Logs
go to CloudWatch with 3-day retention.

I ran RDS as Postgres 16.15 on `db.t4g.micro`, 20GB gp3 storage, single-AZ,
in the private subnets with `publicly_accessible = false`. The only
ingress rule I gave its security group is port 5432 from the EKS cluster
security group, no CIDR-based access at all. I let RDS manage the master
password itself through `manage_master_user_password = true`, which puts
it in Secrets Manager and rotates it on RDS's own schedule rather than
Terraform's. I set `shared_preload_libraries` to `pg_stat_statements` and
`log_min_duration_statement` to 1000ms.

I pinned EKS to 1.35, in standard support, with `upgrade_policy.support_type`
set explicitly to `STANDARD` so it could never drift into paid extended
support. I turned `bootstrap_self_managed_addons` off, so vpc-cni,
kube-proxy, coredns, metrics-server, and the EBS CSI driver became the only
sources of those addons, each pinned to an explicit version rather than
whatever EKS currently defaults to. I used the EKS Access Entries API for
authentication (`authentication_mode = "API"`), not the deprecated
`aws-auth` ConfigMap. The managed node group runs Spot instances. I pinned
the instance type pool in `variables.tf` to `m7i-flex.large` and
`c7i-flex.large` only, both 2 vCPU and 8GiB, because the AWS account this
runs under is on a Free Tier plan that restricts which instance types can
launch at all regardless of vCPU quota, and those were the only two in the
allowed list large enough to be useful EKS nodes. When I checked the
running cluster it had 3 nodes, all `c7i-flex.large`, all on kubelet
`v1.35.7-eks-cb19647`. I left both the control plane API endpoint and the
node group reachable from the public internet
(`endpoint_public_access = true`, `public_access_cidrs = ["0.0.0.0/0"]`),
because GitHub-hosted runners use a rotating IP range I couldn't
meaningfully allowlist. The security boundary here is IAM plus EKS Access
Entries plus RBAC, not the network ACL, and I turned on control plane
audit logging so access stays attributable.

I put the AWS Load Balancer Controller in front of the app to provision an
ALB from its Ingress object, ExternalDNS behind that to watch the Ingress
and write the A/AAAA alias records into the Route53 zone the persistent
layer created, and ACM's wildcard certificate (`chethanraj.site` and
`*.chethanraj.site`) to terminate TLS at the ALB. `terraform/modules/addons`
wires all of that together with External Secrets Operator, which pulls the
RDS-managed secret into a Kubernetes Secret the app mounts and refreshes
hourly, the default gp3 StorageClass, and the observability stack described
below.

## CI/CD

I set `.github/workflows/deploy.yml` to run on every push to `main`. I put
a `test` job first: it installs `app/requirements.txt` and
`app/requirements-dev.txt` and runs `pytest app/tests`, which covers the
liveness/readiness contract and the two DB-failure regression cases with a
monkeypatched `db.get_connection`, never a real Postgres. I gave `deploy`
`needs: test`, so it never runs against a build that failed its own tests.

`deploy` builds the image once. It checks first with
`aws ecr describe-images` whether this commit's SHA tag already exists,
since ECR is immutable and a re-run after a failed `helm upgrade` shouldn't
try to rebuild and fail on `ImageAlreadyExistsException`. I added a second
`describe-images` call after that to resolve the pushed image's digest and
expose it as the job's `image_digest` output. `helm upgrade --install` for
staging still deploys by tag, since staging always wants whatever this
commit's SHA points at. The `production` job, when it runs, deploys by
that resolved digest instead, through `charts/app/values.yaml`'s
`image.digest`, which I made `templates/deployment.yaml` prefer over
`image.tag` whenever it's set. That means production runs the literal
bytes staging's smoke test just validated, not a tag that could in
principle be re-pushed later.

The `production` job's `if` condition is
`github.ref == 'refs/heads/main' && vars.PRODUCTION_ENABLED == 'true'`, and
that variable does not exist in the repository yet. It's deliberately unset,
so the job renders in every run as skipped rather than hanging pending
against a `production` GitHub Environment approval for a cluster that
doesn't exist. When I checked, the `production` Environment does exist and
does have a required-reviewer rule attached to it (repo admins can bypass
it, which GitHub reports as `can_admins_bypass: true`), so the approval gate
itself is real. What isn't ready is everything downstream of it:

`terraform/modules/addons` still hardcodes the namespace name `"staging"` in
`staging_namespace.tf` and in `ci_deploy_rbac.tf`'s RoleBinding. It isn't
parameterized by environment, so applying it against
`terraform/envs/production` would create a namespace literally called
`staging` inside the production cluster instead of `production`, which is
the namespace the EKS access entry I fixed in this pass actually grants
`ci_production` edit access to.

The `ci_production` IAM role in `terraform/persistent/oidc.tf` has a trust
policy and nothing else. It can authenticate over OIDC but has no attached
permissions policy, so it can't call `ecr:GetAuthorizationToken`,
`eks:DescribeCluster`, or anything else the production job's steps need.

The `production` job's `helm upgrade` reads `vars.PROD_RDS_HOST`,
`vars.PROD_RDS_PORT`, `vars.PROD_RDS_DB_NAME`, `vars.PROD_RDS_SECRET_ARN`,
`vars.PROD_ACM_CERTIFICATE_ARN`, and `vars.PROD_APP_HOSTNAME`. I ran
`gh variable list` against this repo and none of the `PROD_*` variables
exist, and `gh secret list` returned nothing at all, so
`secrets.AWS_ACCOUNT_ID` (which the job's `role-to-assume` is built from)
isn't configured either.

That's the full list of what `vars.PRODUCTION_ENABLED` is standing in front
of. `terraform/envs/production` itself plans cleanly today (78 resources to
add, 0 to change, 0 to destroy, checked with `terraform plan`), but I have
not applied it, for cost: it would stand up a second full EKS cluster, RDS
instance, and NAT gateway running continuously, on top of whatever staging
is already costing.

Production reuses the exact same VPC CIDR as staging, `10.0.0.0/16` with the
same four subnet CIDRs, because neither `terraform/envs/production/main.tf`
nor `terraform/envs/staging/main.tf` overrides the vpc module's defaults.
That's safe right now only because they'd be two entirely separate VPC
resources with no peering and no shared routing between them. Two VPCs can
carry identical CIDR blocks with no conflict as long as nothing ever tries
to connect them. It would stop being safe the day anyone adds VPC peering,
a Transit Gateway attachment, or any other route between the two, at which
point one of them would need to be renumbered first.

## Observability

I put kube-prometheus-stack (Prometheus and Grafana, chart 88.6.1) in the
`monitoring` namespace and turned Alertmanager off. I gave Prometheus 2 days
of retention with a 4GB size cap, on an emptyDir rather than a PVC, because
gp3 is `WaitForFirstConsumer` and the cluster is rebuilt nightly, so the
data has no value across a rebuild and an EBS volume would be one more
thing `pre-destroy.sh` has to sequence correctly. I instrumented the app
with `prometheus-fastapi-instrumentator` to expose `/metrics`, scraped by a
ServiceMonitor whose `release: kube-prometheus-stack` label matches the
chart's default selector.

I ran Loki (chart 7.3.0) in `SingleBinary` mode, also on an emptyDir, with
48-hour retention and `replication_factor: 1`. Getting the emptyDir right
took a real debugging pass. Setting `singleBinary.persistence.enabled:
false` alone did not make this chart fall back to an emptyDir the way
prometheus-operator does. It just omitted the `/var/loki` volume entirely,
and since the Loki container ran `readOnlyRootFilesystem: true`, the
ruler module's `mkdir /var/loki/ruler-wal` failed on startup with a
read-only filesystem error and the pod crash-looped. I fixed it with an
explicit `singleBinary.extraVolumes`/`extraVolumeMounts` pair that provides
the emptyDir directly, and disabled the ruler since nothing here uses
alerting rules. The full incident is in `CHALLENGES.md`. I added a
promtail DaemonSet (chart 6.17.1) to ship pod logs to Loki. I chose
promtail over Grafana Alloy for this because Alloy's configuration is its
own River-based language, and writing a DaemonSet that does exactly one
thing, tailing every container's logs and pushing them to one Loki
endpoint, in River felt like more surface area than promtail needed for
the same job under the time I had. promtail is in maintenance mode
upstream, so this is a reasonable thing to revisit later, not a permanent
choice.

I shipped two custom dashboards as Kubernetes ConfigMaps labeled
`grafana_dashboard: "1"`, picked up by the sidecar kube-prometheus-stack's
Grafana already runs by default. That's the same reason I built the
dashboards as ConfigMaps at all rather than in the Grafana UI: a UI-built
dashboard lives only in Grafana's SQLite database, which sits on an
emptyDir here, so it would not survive a single nightly rebuild. As
ConfigMaps they're in git, applied by the same `terraform apply` that
builds the cluster, and reviewable in a diff. I left the 28 dashboards
bundled with kube-prometheus-stack untouched.

I didn't give the platform dashboard an ALB target-health panel, because
that metric doesn't exist here. Getting it would mean running a CloudWatch
exporter to scrape `AWS/ApplicationELB` and `AWS/TargetGroup` metrics,
which this platform deliberately doesn't do. Instead the platform
dashboard's "App targets up" panel queries `sum(up{job="app"})`, which is
Prometheus's own scrape-health signal for the app's ServiceMonitor
targets, and the app dashboard's "Replicas and restarts" panel queries
`kube_deployment_status_replicas_available{namespace="staging"}` from
kube-state-metrics. Neither one tells me whether the ALB itself considers a
target healthy, only whether the pods behind it are up and Prometheus can
reach them.

## Security

I gave every addon that talks to an AWS API its own IRSA role, scoped by an
OIDC `sub` condition to one exact Kubernetes service account. The EBS CSI
driver, ExternalDNS, External Secrets Operator, and the AWS Load Balancer
Controller each got a separate `aws_iam_role` with a federated trust policy
naming its own `system:serviceaccount:<namespace>:<name>`. None of them
share a role, and I avoided a wildcard resource on any attached IAM policy
except where AWS's own API genuinely has no resource-level permission
support for that action, which was `ecr:GetAuthorizationToken`,
`route53:ListHostedZones`, and the AWS Load Balancer Controller's own
published policy, which I downloaded rather than hand-wrote.

CI never holds a static AWS key. `terraform/persistent/oidc.tf` creates one
GitHub Actions OIDC provider and two IAM roles off it, and I read the trust
policy on each rather than describe it from memory. The `ci_deploy` role's
trust policy checks `token.actions.githubusercontent.com:aud` equals
`sts.amazonaws.com` and `token.actions.githubusercontent.com:sub` equals
one of `repo:Chethann-Raj/eks-platform:ref:refs/heads/main` or the
immutable-ID equivalent
`repo:Chethann-Raj@148512002/eks-platform@1351373185:ref:refs/heads/main`.
Both forms exist because this repo was created after GitHub's July 2026
cutover to immutable subject claims, and GitHub may issue either spelling
until CloudTrail confirms which one it actually sends. That condition is an
exact match against a ref, not an environment. Any workflow run on `main`
in this repo can assume `ci_deploy`, with no approval step involved. The
`ci_production` role's trust policy checks the same `aud` condition but a
different `sub`: one of `repo:Chethann-Raj/eks-platform:environment:production`
or its immutable-ID equivalent. GitHub only issues a token with an
`:environment:` subject, rather than a `:ref:` one, after that named
Environment's protection rules are satisfied, which is what makes the
required-reviewer approval a real gate on `ci_production` and not one on
`ci_deploy`. I confirmed separately that `main` itself has no branch
protection rule at all (`gh api repos/.../branches/main/protection`
returned 404, branch not protected), so nothing stops a direct push to
`main` from reaching the `ci_deploy`-gated staging deploy. The
`environment: production` gate is the only approval control in this
pipeline.

RDS's master credentials live in Secrets Manager, created and rotated by
RDS itself. I got them to the app pod through an ExternalSecret that pulls
only the `username` and `password` keys into a mounted Kubernetes Secret
file, re-read on every new database connection rather than injected as an
environment variable, so a rotation takes effect without a pod restart. I
encrypted EKS's Kubernetes Secrets with a customer-managed KMS key
(`terraform/persistent/kms.tf`) and turned on key rotation for it.

I blocked `/metrics` at the ALB. The app's Ingress has an explicit
`path: /metrics` rule ahead of the catch-all `/` rule, using an ALB
fixed-response action that returns 404, because a single `/` prefix rule
would otherwise have forwarded every path including `/metrics` straight
through to the public internet. Prometheus reaches `/metrics` in-cluster
only, through the ServiceMonitor hitting the pod directly.

I put both the EKS nodes and the RDS instance in private subnets with no
route to the internet gateway, and set `publicly_accessible = false` on
RDS as well. I set ECR's repository to `image_tag_mutability = "IMMUTABLE"`,
so a tag can never be silently repointed at a different image once pushed,
which is also what the production job's digest-based promotion depends on
for its promise to mean anything.

There are three things I'm not going to describe as more solved than they
are. The Grafana admin password is generated by a `random_password`
resource and stored in a Kubernetes Secret, which means it lands in the
Terraform state file in plaintext. `sensitive = true` on that resource's
`result` attribute only keeps it out of `plan`/`apply` output, not out of
the state file itself. That's mitigated by the state bucket having SSE-S3
encryption and blocked public access, not eliminated: anyone with S3 read
access to that object, or running `terraform state pull` against it, can
recover the password. The KMS key encrypting EKS's Kubernetes Secrets is
shared across every environment rather than one per environment, by design,
because a key scoped to the nightly-rebuilt staging environment would keep
its alias allocated for the entire 30-day deletion window after each
teardown and break the next morning's `terraform apply`. And with `main`
unprotected, the `production` Environment's required-reviewer rule has
nothing upstream of it enforcing that only reviewed code reaches `main` in
the first place. It's a real gate on who can trigger a production deploy,
not a guarantee about what's in the commit being deployed.

## Scope cuts

I turned Alertmanager off. Nothing here pages anyone, and standing up a
second component to route alerts nobody would receive wasn't worth the
node capacity on a 3-node Spot pool this size.

I chose promtail over Grafana Alloy for the log-shipping DaemonSet, covered
above under Observability, for config simplicity under the time I had
rather than because Alloy couldn't do it.

I disabled Loki's `chunksCache` and `resultsCache`. Their default is a
memcached deployment requesting several gigabytes each, which alone would
have exceeded this node group's smallest node. At this log volume neither
cache did enough to be worth resizing down instead of turning off.

I left out a CloudWatch exporter, so RDS's host-level metrics, CPU,
FreeableMemory, IOPS, and DiskQueueDepth, aren't in Grafana at all. Those
are hypervisor-level metrics about a host I don't have shell access to.
They only exist in CloudWatch, and getting them into Prometheus would mean
running another exporter against another AWS API for metrics this platform
doesn't currently act on.

## Verify it works

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://chethanraj.site/
# 200

curl -sI -o /dev/null -w '%{http_code}\n' https://chethanraj.site/
# 405 - this is curl -I sending a HEAD request, not a real failure.
# Starlette doesn't auto-register HEAD for a route declared with
# @app.get(...), so anything checking this site's health has to use GET.

curl -s -o /dev/null -w '%{http_code}\n' https://chethanraj.site/metrics
# 404, blocked at the ALB on purpose

curl -s https://chethanraj.site/api/stats
# {"message":"Hello from eks-platform","visits":70}
```

Querying Loki directly for the app's own logs:

```bash
kubectl -n monitoring port-forward svc/loki 3100:3100 &
curl -sG 'http://localhost:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={namespace="staging"}' \
  --data-urlencode 'limit=3' \
  | python3 -c "import sys,json; d=json.load(sys.stdin)['data']['result']; print('streams:', len(d)); [print(s['stream'].get('pod'), '|', s['values'][0][1][:100]) for s in d[:3]]"
kill %1
```

When I ran this it returned one stream:

```
streams: 1
app-f5f48c5b-9ft9m | INFO:     10.0.11.148:54432 - "GET /healthz HTTP/1.1" 200 OK
```

Checking that Grafana actually picked up the Loki datasource:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 &
PW=$(kubectl -n monitoring get secret eks-platform-staging-grafana-admin \
  -o jsonpath='{.data.admin-password}' | base64 -d)
curl -s -u admin:"$PW" http://localhost:3000/api/datasources \
  | python3 -c "import sys,json; [print(d['name'], d['type'], d['url']) for d in json.load(sys.stdin)]"
kill %1
```

Which returned:

```
Alertmanager alertmanager http://kube-prometheus-stack-alertmanager.monitoring:9093/
Loki loki http://loki.monitoring.svc.cluster.local:3100
Prometheus prometheus http://kube-prometheus-stack-prometheus.monitoring:9090/
```

The Alertmanager entry there is the chart's own default datasource
provisioning, pointing at a Service that doesn't actually exist since
Alertmanager is disabled. Loki is the one this check cares about, and it's
wired to the right in-cluster URL with no Terraform apply beyond the
ConfigMap that provisions it.
