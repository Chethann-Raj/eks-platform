# terraform/modules/vpc

Reusable networking module: 2 AZs, public + private subnets, a single shared
NAT Gateway, EKS subnet discovery tags, and VPC Flow Logs to CloudWatch.
Per `CLAUDE.md` §7.

## Why this has no backend, no provider block, and can't `plan` standalone

This is a **child module**, not a root module:

- It has no `backend` block. Terraform backends are configured once, at the
  root (`terraform/envs/staging/backend.tf`) - a child module inherits
  whichever state/backend the root that calls it is using.
- It has no `provider "aws" {}` block, only `required_providers` (the
  version constraint). Provider configuration (region, profile,
  `default_tags`) is inherited from the calling root module.

Because of both, `terraform init`/`plan`/`apply` don't work run standalone
inside this directory - there's no backend to init and no configured
provider to talk to AWS with. It only becomes plannable once
`terraform/envs/staging/` has a `module "vpc" { source = "../../modules/vpc"
... }` block referencing it. The provider version pin here still matters: it
constrains what the root's `required_providers` resolves to when composed.

## Design notes

- **Single NAT Gateway**, not one per AZ: ~$32/mo cheaper, at the cost of an
  AZ-level single point of failure for private-subnet egress if that AZ has
  an outage. Placed in the first of the two public subnets (AZs are sorted
  for deterministic ordering across plans).
- **One private route table per AZ**, even though both hold an identical
  route to the single shared NAT Gateway today. This is set up ahead of
  Phase 5's fck-nat-per-AZ optimisation, so that swap only means changing
  which target each AZ's table points at, not restructuring from one shared
  table into several.
- **S3 Gateway endpoint**, associated with every route table (public + both
  private). Gateway endpoints are free - no hourly charge, no per-GB charge -
  unlike the NAT Gateway's $0.045/GB. Loki writes to S3 continuously in
  Phase 4; without this endpoint that traffic (and ECR image layer pulls,
  which are S3-backed) would traverse and be billed through the NAT Gateway
  for no reason.
- **No Interface endpoints** (for ECR API, EKS, CloudWatch Logs, etc.),
  deliberately. Interface endpoints cost ~$0.01/hr *per AZ* regardless of
  traffic volume - on a cluster torn down and rebuilt nightly, that's a
  standing charge for capacity that only exists a few hours a day. Gateway
  endpoints (S3, and DynamoDB if ever needed) are the only free tier, so
  they're the only ones added. Revisit if the project moves off nightly
  teardown.
- `public_subnet_tags` / `private_subnet_tags` let the caller merge in
  `kubernetes.io/cluster/<name> = shared` once the cluster name exists,
  without this module needing to know about EKS at all.
- VPC Flow Logs go to CloudWatch Logs with a 3-day retention default
  (`flow_log_retention_days`), not S3 - matches CLAUDE.md §7.
