# terraform/persistent

Built once, read by `terraform/envs/staging/` via `terraform_remote_state`,
never destroyed by the nightly teardown - this is where anything whose
identity must survive a rebuild (hosted zone, ACM cert, ECR repo, OIDC
provider) lives.

## Namecheap delegation (required before the ACM cert can validate)

1. Run `terraform apply` here. `aws_route53_zone.primary` is created first;
   `terraform output hosted_zone_name_servers` prints the four `*.awsdns-*`
   nameservers Route53 assigned.
2. In the Namecheap dashboard: **Domain List → chethanraj.site → Manage →
   Nameservers → Custom DNS**, and enter those four nameservers exactly as
   printed (no trailing dots).
3. Save. Propagation is usually fast but not instant.
4. Verify from a terminal:
   ```bash
   dig +short NS chethanraj.site
   ```
   Once this returns the same four `awsdns` nameservers Route53 assigned
   (not Namecheap's defaults), delegation has propagated.

`aws_acm_certificate_validation.wildcard` blocks in `terraform apply` until
ACM can resolve the DNS validation records this module already created in
the zone - i.e. until step 4 is true. If `apply` times out first, delegation
hadn't propagated yet in time; re-running `apply` continues waiting, no
resources are recreated.

## Provider lock

Same as `terraform/bootstrap`: run
`terraform providers lock -platform=darwin_arm64 -platform=linux_amd64`
after `init` so the committed lock file works both on this Mac and on
GitHub Actions' `ubuntu-latest` runners.

## EKS Kubernetes Secrets encryption key

`aws_kms_key.eks` (`kms.tf`) lives here rather than in
`terraform/modules/eks/`, because `envs/staging` is destroyed nightly: a key
scheduled for deletion keeps its alias allocated for the entire deletion
window, so the next rebuild's `terraform apply` would fail trying to
recreate `alias/eks-platform-eks-secrets` - and every nightly teardown would
leave behind another billable key sitting in `PendingDeletion`. The eks
module takes this key's ARN as `var.kms_key_arn`, an input, not something it
creates.

**This is irreversible.** Once a cluster's `encryption_config` references
this key, scheduling it for deletion permanently breaks decryption of every
Kubernetes Secret encrypted with it - there is no recovery once the deletion
window elapses. Never run `terraform destroy` against this key (or this
whole persistent layer) while a live cluster still references it.

## What's deliberately not here yet

The two IAM roles (`ci_deploy`, `ci_production`) have trust policies only.
Phase 3 attaches the actual least-privilege permission policies (ECR push,
EKS auth) once the CI workflows that use them are written - attaching
permissions now would mean guessing at actions before they're needed.
