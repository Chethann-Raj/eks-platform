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
# environment-gated) job run is `repo:<org>/<repo>:ref:<git ref>`. Pinning it
# with StringEquals (not StringLike/wildcards) to exactly
# "repo:Chethann-Raj/eks-platform:ref:refs/heads/main" blocks:
#   - any other repository, including a fork of this public repo - a fork's
#     workflow gets a `sub` of "repo:someone-else/eks-platform:ref:..." which
#     does not match.
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
      values   = ["repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "ci_deploy" {
  name               = "${var.project}-ci-deploy"
  assume_role_policy = data.aws_iam_policy_document.ci_deploy_trust.json

  # No permission policy attached yet - Phase 3 attaches least-privilege
  # policies (ECR push, EKS auth) once the exact workflow actions are defined.
}

# --- Production role: assumed only by a job using the "production" ---------
# --- GitHub Environment -----------------------------------------------------
#
# When a job specifies `environment: production`, GitHub only issues the
# OIDC token - and only sets `sub` to
# "repo:<org>/<repo>:environment:<name>" - after that environment's
# protection rules (required reviewers, wait timer, etc.) are satisfied.
# StringEquals on that exact string blocks:
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
      values   = ["repo:${var.github_org}/${var.github_repo}:environment:production"]
    }
  }
}

resource "aws_iam_role" "ci_production" {
  name               = "${var.project}-ci-production"
  assume_role_policy = data.aws_iam_policy_document.ci_production_trust.json

  # No permission policy attached yet - see ci_deploy above.
}
