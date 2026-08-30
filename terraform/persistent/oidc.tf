data "aws_caller_identity" "current" {}

locals {
  # "staging" is hardcoded here, not read from envs/staging's remote state:
  # persistent must never depend on staging's state (staging depends on
  # persistent via terraform_remote_state, not the other way around - a
  # circular dependency would mean neither could ever apply first). This
  # must match envs/staging's own computed cluster name
  # ("${var.project}-${var.environment}" there, with environment =
  # "staging") - if that ever changes, update this too.
  staging_cluster_arn = "arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${var.project}-staging"

  # Two `sub` claim prefixes for the same repo - see CHALLENGES.md's
  # "fourth failure class" entry. This repo was created 2026-08-30, after
  # GitHub's 2026-07-15 cutover for automatic immutable subject claims, so
  # GitHub may issue either the legacy name-based prefix or the new
  # ID-based one; every trust policy below accepts both until CloudTrail
  # confirms which one is actually sent, at which point this should be
  # narrowed back to a single value.
  github_sub_legacy_prefix    = "repo:${var.github_org}/${var.github_repo}"
  github_sub_immutable_prefix = "repo:${var.github_org}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}"
}

# GitHub's OIDC token-issuing endpoint. Fetched dynamically rather than
# hardcoding a thumbprint, which rotates whenever GitHub's TLS cert renews.
data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

# --- CI deploy role: assumed only by workflow runs on refs/heads/main ------
#
# The `sub` claim GitHub embeds in the OIDC token for a normal (non
# environment-gated) job run is `repo:<org>/<repo>:ref:<git ref>` - except
# GitHub may substitute the ID-based immutable prefix for the
# "repo:<org>/<repo>" portion instead, per local.github_sub_immutable_prefix
# above. StringEquals against a LIST is an OR, and both values identify the
# exact same repository and branch - this accepts either spelling of "this
# repo, on main" without accepting anything broader. It's still exact-match
# (not StringLike/wildcards), so this still blocks:
#   - any other repository, including a fork of this public repo - a fork's
#     workflow gets a `sub` for a different repo/ID pair entirely, matching
#     neither value.
#   - any other ref in *this* repo - feature branches, PR branches (whose
#     `sub` is "repo:...:pull_request", not a ref at all), and tags.
# The `aud` condition additionally blocks any OIDC token GitHub issued for a
# different audience from being replayed here.
data "aws_iam_policy_document" "ci_deploy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${local.github_sub_legacy_prefix}:ref:refs/heads/main",
        "${local.github_sub_immutable_prefix}:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "ci_deploy" {
  name               = "${var.project}-ci-deploy"
  assume_role_policy = data.aws_iam_policy_document.ci_deploy_trust.json
}

# Phase 3: .github/workflows/deploy.yml needs to (1) push an image to ECR
# and (2) authenticate to the EKS API server to run `helm upgrade`. Nothing
# else - it never calls AWS to read RDS/ACM/ECR endpoint values (those are
# passed in as GitHub Actions repository variables, set once from Terraform
# output, rather than granted as read permissions this role doesn't
# otherwise need).
data "aws_iam_policy_document" "ci_deploy_permissions" {
  statement {
    sid    = "ECRAuth"
    effect = "Allow"
    # ecr:GetAuthorizationToken returns a short-lived Docker login token,
    # not access to any specific repository - AWS does not support
    # resource-level permissions for this action (CLAUDE.md §2).
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPushThisRepoOnly"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      # Backs the describe-images guard in deploy.yml: ECR is IMMUTABLE, so
      # PutImage on a tag that already exists (a re-run of this workflow
      # for the same commit, after an earlier run failed at `helm upgrade`
      # rather than at the build) throws ImageAlreadyExistsException. The
      # workflow checks first and skips the build+push in that case.
      "ecr:DescribeImages",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  statement {
    sid       = "EKSAuth"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [local.staging_cluster_arn]
  }
}

resource "aws_iam_role_policy" "ci_deploy_permissions" {
  name   = "${var.project}-ci-deploy"
  role   = aws_iam_role.ci_deploy.id
  policy = data.aws_iam_policy_document.ci_deploy_permissions.json
}

# --- Production role: assumed only by a job using the "production" ---------
# --- GitHub Environment -----------------------------------------------------
#
# When a job specifies `environment: production`, GitHub only issues the
# OIDC token - and only sets `sub` to
# "repo:<org>/<repo>:environment:<name>" - after that environment's
# protection rules (required reviewers, wait timer, etc.) are satisfied.
# Same immutable-subject substitution as ci_deploy above applies here too:
# the "repo:<org>/<repo>" prefix is repo-wide, not specific to the `:ref:`
# suffix, so an `:environment:` sub claim is equally affected. Same fix:
# StringEquals against both prefix spellings (still an exact-match OR, not
# a widening) - see local.github_sub_immutable_prefix's comment. This
# still blocks:
#   - any other repository/fork, same reasoning as above.
#   - any job in this repo that does NOT declare `environment: production`
#     (e.g. the main.yml staging deploy), even though it's the same repo.
#   - a job that references a *different* named environment.
data "aws_iam_policy_document" "ci_production_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${local.github_sub_legacy_prefix}:environment:production",
        "${local.github_sub_immutable_prefix}:environment:production",
      ]
    }
  }
}

resource "aws_iam_role" "ci_production" {
  name               = "${var.project}-ci-production"
  assume_role_policy = data.aws_iam_policy_document.ci_production_trust.json

  # No permission policy attached yet - see ci_deploy above.
}
