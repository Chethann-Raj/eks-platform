# terraform/envs/staging

Wires `vpc` + `eks` + `rds` together for the environment that's destroyed and
rebuilt nightly (`CLAUDE.md` §6). This is the only layer with its own
`provider "aws" {}` block - every module under `terraform/modules/` inherits
it.

## Remote state

Reads `terraform/persistent/` via `data.terraform_remote_state.persistent`,
pointed at the exact bucket/key from `terraform/persistent/backend.tf`
(`chethanraj-eks-platform-tfstate` / `persistent/terraform.tfstate`) rather
than a guess. Currently consumes two of its outputs:

- `eks_kms_key_arn` → `module.eks`'s `kms_key_arn`. This key is irreversible
  to delete while referenced - see the persistent README for why it can't
  live here.
- `ci_deploy_role_arn` → the `ci_deploy` access entry below.

Nothing from the persistent layer (hosted zone, ACM cert, ECR) is
duplicated here - Phase 2 wires those into the addons/app layer when it's
needed.

## EKS access entries (CLAUDE.md §8)

Two, both required or Phase 3's first `helm upgrade` fails with an
authentication error:

1. `data.aws_caller_identity.current.arn` (the identity running `terraform
   apply` - `terraform-admin` under the `pro` profile) →
   `AmazonEKSClusterAdminPolicy`, cluster-scoped. Never a literal ARN -
   CLAUDE.md §2.
2. `ci_deploy_role_arn` from the persistent layer →
   `AmazonEKSEditPolicy`, scoped to the `staging` namespace only.

## RDS: staging overrides the module's production-oriented defaults

`terraform/modules/rds` defaults to `deletion_protection = true`,
`skip_final_snapshot = false`, `backup_retention_period = 7` - safe for
something meant to persist. This environment is the opposite: destroyed
every night on purpose. `module "rds"` here explicitly sets

```hcl
deletion_protection     = false # staging only, nightly teardown
skip_final_snapshot     = true  # staging only, nightly teardown
backup_retention_period = 0     # staging only, nightly teardown
```

`deletion_protection = true` would hard-fail every nightly `terraform
destroy`; `skip_final_snapshot = false` would require a final snapshot this
environment has no use for (and, per the rds module's README, would collide
on the second night since that snapshot's name is static, not timestamped);
`backup_retention_period = 7` would mean paying for a week of point-in-time
recovery on a database that won't exist in a few hours.

## Subnet discovery tags

`module "vpc"`'s `public_subnet_tags`/`private_subnet_tags` are set to
`{ "kubernetes.io/cluster/<name>" = "shared" }` here, where `<name>` is
computed locally (`local.cluster_name = "${var.project}-${var.environment}"`)
to match the eks module's own internal naming - needed so this environment
doesn't ship with the vpc module's subnet-tagging feature built but unused.
This is what lets the AWS Load Balancer Controller (Phase 2) and other
cluster-aware tooling find these subnets by cluster, in addition to the
`kubernetes.io/role/elb`/`internal-elb` tags the vpc module always sets.

## `terraform.tfvars`

Committed, and contains no secrets - just region/profile and the pinned
version strings (`kubernetes_version`, `engine_version`, `instance_class`).
Every other module input either has a safe default already set inside the
module it belongs to, or is wired here from another module's/persistent's
output, not from a variable that needs a value supplied per environment.
