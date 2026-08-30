# terraform/bootstrap

Creates the S3 bucket that every other layer (`terraform/persistent/`,
`terraform/envs/staging/`) uses as its remote state backend.

## Chicken-and-egg: why this module uses local state

Every other layer stores its state in the bucket this module creates. This
module can't do the same for its own state — the bucket wouldn't exist yet on
a first run. So `terraform/bootstrap/` deliberately uses **local state**
(the default backend, no `backend` block).

Consequences:

- `terraform.tfstate` for this module lives on disk under this directory. It
  is gitignored (see repo root `.gitignore`) and must never be committed —
  even though it holds no secrets here (just an S3 bucket ID/ARN), state
  files as a class are excluded repo-wide per `CLAUDE.md` §9.
- Re-running `terraform apply` in this directory is safe and idempotent:
  if the bucket already exists in AWS but the local state file was lost
  (new machine, wiped `.terraform`), re-bootstrapping will fail on
  `BucketAlreadyOwnedByYou` unless you `terraform import` the bucket back
  into a fresh local state first. This is intentionally a one-time, mostly
  manual module — it is run once per AWS account, not on every rebuild.

## Locking: no DynamoDB table

State locking for the *other* layers is handled by each of their own
`backend "s3"` blocks setting `use_lockfile = true`, not by anything created
here. See the comment in `main.tf` for the reasoning (S3 conditional writes
vs. a DynamoDB lock table). This module needs no lock table for itself since
it isn't using the S3 backend at all.

## Usage

```bash
cd terraform/bootstrap
terraform init
terraform providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform plan
terraform apply   # run by the human, not by Claude
```

Then wire the output `state_bucket_name` into the `backend "s3"` block of
`terraform/persistent/` and `terraform/envs/staging/`.

## Why the provider lock file needs both platforms

`.terraform.lock.hcl` only records provider package hashes for the
platform(s) it was generated on. By default that's whatever machine ran
`terraform init` — here, macOS on Apple Silicon (`darwin_arm64`). CI
(GitHub Actions `ubuntu-latest`) runs on `linux_amd64`. Without a hash
recorded for `linux_amd64`, `terraform init` in CI fails signature
verification because the committed lock file has nothing to check the
downloaded Linux provider binary against.

`terraform providers lock -platform=darwin_arm64 -platform=linux_amd64` adds
hashes for both, so the same committed lock file works on the dev laptop and
in CI. Every layer's lock file (`bootstrap`, `persistent`, `envs/staging`)
must be generated this way, not with a bare `terraform init`.
