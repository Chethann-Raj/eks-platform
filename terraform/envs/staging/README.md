# terraform/envs/staging

Wires `vpc` + `eks` + `rds` together for the environment that's destroyed and
rebuilt nightly. This is the only layer with its own
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

## EKS access entries

Two, both required or Phase 3's first `helm upgrade` fails with an
authentication error:

1. `data.aws_caller_identity.current.arn` (the identity running `terraform
   apply` - `terraform-admin` under the `pro` profile) →
   `AmazonEKSClusterAdminPolicy`, cluster-scoped. Never a literal ARN,
   since a hardcoded account ID or role ARN breaks the moment this runs
   under a different AWS account or profile.
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

## Verifying the Phase 3 IRSA in-place "updates" are cosmetic, post-apply

`phase3.tfplan` shows `aws_iam_role.external_dns`/`external_secrets`/`lbc`
(and their `aws_iam_role_policy` documents) as "updated in-place" even
though nothing about their actual trust or permission content changed -
see CHALLENGES.md for why (`module.addons`'s module-level `depends_on
[module.eks]` defers several data sources to apply-time whenever anything
in `module.eks` changes, which makes Terraform show their dependents as
"known after apply" without there being a real diff). To confirm that
after applying, diff the actual IAM trust policy before and after:

```bash
# Before apply, for each of the three IRSA roles (note the LBC role's real
# name - it is NOT "eks-platform-staging-lbc"):
for r in external-dns external-secrets aws-load-balancer-controller; do
  aws iam get-role --role-name "eks-platform-staging-$r" \
    --query 'Role.AssumeRolePolicyDocument' --profile pro \
    > "/tmp/before-$r.json"
done

# ... run terraform apply phase3.tfplan ...

# After apply, diff each - every one should be empty (no output = identical):
for r in external-dns external-secrets aws-load-balancer-controller; do
  aws iam get-role --role-name "eks-platform-staging-$r" \
    --query 'Role.AssumeRolePolicyDocument' --profile pro \
    > "/tmp/after-$r.json"
  echo "=== $r ==="
  diff "/tmp/before-$r.json" "/tmp/after-$r.json"
done
```

If any of the three produce non-empty `diff` output, the "cosmetic"
explanation above is wrong for that role and it needs real investigation -
don't assume it's benign a second time without checking.

**Verified post-apply:** `external-secrets` was byte-identical;
`external-dns` and `aws-load-balancer-controller` differed only in JSON key
order (`sub`/`aud` reordered within the same `Condition.StringEquals`
block, identical values) - confirmed cosmetic, not a real change.

## `terraform.tfvars`

Committed, and contains no secrets - just region/profile and the pinned
version strings (`kubernetes_version`, `engine_version`, `instance_class`).
Every other module input either has a safe default already set inside the
module it belongs to, or is wired here from another module's/persistent's
output, not from a variable that needs a value supplied per environment.
