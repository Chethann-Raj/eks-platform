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
