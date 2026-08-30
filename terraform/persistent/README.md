# terraform/persistent

Built once, read by `terraform/envs/staging/` via `terraform_remote_state`,
never destroyed by the nightly teardown. See `CLAUDE.md` §6.

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

## What's deliberately not here yet

The two IAM roles (`ci_deploy`, `ci_production`) have trust policies only.
Phase 3 attaches the actual least-privilege permission policies (ECR push,
EKS auth) once the CI workflows that use them are written - attaching
permissions now would mean guessing at actions before they're needed.
