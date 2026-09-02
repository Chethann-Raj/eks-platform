# terraform/modules/rds

Reusable RDS PostgreSQL module: subnet group, a locked-down security group,
a parameter group tuned for observability, and the instance itself with
RDS-managed credentials - Postgres 16 on `db.t4g.micro`/20GB gp3,
password never touching Terraform state or outputs.

## Why this can't `plan` standalone

Same as `vpc` and `eks`: no `backend` block, no `provider "aws" {}` block,
only `required_providers`. It's a child module, plannable only once
`envs/staging` composes it with the vpc and eks modules' outputs as inputs.

## PostgreSQL version

Pinned to `16.15`. Queried the actually-available versions rather than
guessing:

```bash
aws rds describe-db-engine-versions --engine postgres \
  --region ap-south-1 --profile pro \
  --query 'DBEngineVersions[?starts_with(EngineVersion,`16.`)].EngineVersion' \
  --output text
# 16.9  16.10  16.11  16.12  16.13  16.14  16.15
```

`16.15` was confirmed `Status: available`, not deprecated. The parameter
group's `family` (`aws_db_parameter_group.this`) is derived from
`var.engine_version` (`"postgres${split(".", var.engine_version)[0]}"`)
rather than a second hardcoded variable, so the two can't drift apart if
`engine_version` is bumped later without updating the family separately.

## Why `db.t4g.micro`

Sized for a portfolio-scale workload (a handful of tables, low write
volume) sharing a 3-node/5.7 vCPU cluster, not for real production
throughput.
`t4g.micro` is Graviton (cheaper per vCPU than `t3`), burstable, and free-tier
eligible - there's no throughput requirement here that would justify a
bigger, non-burstable class.

## Private-subnet placement, no public access

`aws_db_subnet_group.this` only ever gets `var.private_subnet_ids`, and
`publicly_accessible = false` is hardcoded, not a variable - there's no
scenario in this project where the database should be reachable from
outside the VPC. Private subnets are for nodes and RDS, full stop; the
ALB and NAT Gateway are the only things that belong in public subnets.

## Security group: "5432 from nodes" is an approximation

`aws_security_group.rds` has exactly one ingress rule: TCP 5432 from
`var.node_security_group_id`, no CIDR ingress at all. In `envs/staging` that
variable is wired to the **eks** module's `node_security_group_id` output -
which, as documented there, is EKS's auto-created cluster security group
(`aws_eks_cluster.this.vpc_config[0].cluster_security_group_id`), not a
security group scoped only to worker nodes. That same SG is also attached to
the EKS control plane's own ENIs. In practice this means "5432 reachable
from anything wearing the cluster SG" is a slightly broader statement than
"5432 reachable from worker nodes" - the control plane ENIs could in
principle also open a connection, though nothing in this stack has them do
so. This module doesn't second-guess that scope; it takes whatever security
group ID it's handed and trusts the caller's documentation of what that ID
actually covers.

No `egress` block is declared on the security group at all (not even an
empty one). `ingress`/`egress` on `aws_security_group` are independently
optional+computed attributes - omitting `egress` entirely leaves AWS's own
auto-created "allow all outbound" rule alone, rather than Terraform
reconciling it down to nothing. There's no requirement here to restrict what
this database can call out to, so there's no reason to take on managing
that.

## `multi_az = false`

Hardcoded, not a variable - single-AZ RDS is a deliberate cost trade-off
(one instance's worth of compute/storage instead of two, no synchronous
standby) accepted for a project that's rebuilt nightly and has no uptime
SLA. **What changes at production scale:** flip this to `true` (the module
already spans 2 AZs via `var.private_subnet_ids`, so no subnet changes
needed) to get an automatically-failed-over standby in the second AZ,
at roughly double the RDS compute+storage cost.

## `backup_retention_period` / `skip_final_snapshot` / `deletion_protection`

The module defaults are **production-oriented**, not staging-oriented:

| Variable | Module default | Why |
|---|---|---|
| `backup_retention_period` | `7` | A week of point-in-time recovery is a reasonable minimum for anything meant to persist. |
| `skip_final_snapshot` | `false` | Destroying a production database without a last snapshot is how real data gets lost permanently. |
| `deletion_protection` | `true` | An accidental `terraform destroy` (or a typo'd `-target`) shouldn't be able to take out the database in one step. |

`envs/staging` is expected to **explicitly override all three** to
`backup_retention_period = 1`, `skip_final_snapshot = true`,
`deletion_protection = false` for its nightly teardown - a database that's
destroyed and recreated every night has no use for backups that outlive it,
must be able to be destroyed without manual intervention (`deletion_protection
= true` would hard-fail every nightly `terraform destroy`), and skipping the
final snapshot avoids two problems at once: the nightly destroy not hanging
on a snapshot it doesn't need, and `final_snapshot_identifier` colliding on
the second night (see the comment in `main.tf` - that name is static, not
timestamped, specifically to avoid a perpetual diff, which means a repeated
snapshot-taking destroy would need the prior snapshot deleted or renamed
first). This module intentionally does not hardcode either the staging or
the production behavior; it only supplies safe defaults and expects the
caller to be explicit.

## `pg_stat_statements` requires a reboot

`shared_preload_libraries` is a `PGC_POSTMASTER`-context parameter in
Postgres - the server only reads it once, at process start. Changing it
can't take effect until the instance restarts, so
`aws_db_parameter_group.this` sets `apply_method = "pending-reboot"`
specifically on that parameter. `log_min_duration_statement` is an ordinary
runtime-settable parameter and applies immediately (the default
`apply_method`), no reboot required. After the first apply that sets
`shared_preload_libraries`, the instance needs one manual reboot
(`aws rds reboot-db-instance`) before `pg_stat_statements` is actually
loaded - Terraform doesn't reboot the instance for you.

## Storage encryption

`storage_encrypted = true`, always. `kms_key_id = var.kms_key_arn`, which is
nullable: passing `null` (the default) uses AWS's default `aws/rds`
managed key; passing a real ARN uses a customer-managed key instead. No
resource in this module creates a KMS key - that decision (and the key
itself, if a customer-managed one is wanted) belongs to the caller, the same
pattern used for the eks module's `kms_key_arn`.

## Performance Insights

`performance_insights_enabled = true`, `performance_insights_retention_period
= 7` (the free tier - the two facts are tied together, 7 days is exactly
where Performance Insights stops being free). No enhanced monitoring and no
additional IAM monitoring role are configured - deliberately out of scope
for this module.

## RDS-managed credentials

`manage_master_user_password = true`: RDS creates and rotates the master
password itself in Secrets Manager. There is no `password` argument in this
module, no password in Terraform state, and no password in any output -
`master_user_secret_arn` (from `aws_db_instance.this.master_user_secret[0].
secret_arn`) is the only credential-adjacent value exposed, and it points at
the secret, not its contents. `master_user_secret_kms_key_id` is
deliberately left unset, so that secret is encrypted with the AWS-managed
`aws/secretsmanager` key rather than a customer-managed one - consistent
with not standing up KMS infrastructure this module has no other need for.
Phase 2's External Secrets Operator reads the actual credentials out of
Secrets Manager via this ARN at runtime; Terraform never sees them.
