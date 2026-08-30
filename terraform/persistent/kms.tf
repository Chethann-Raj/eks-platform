# EKS Kubernetes Secrets encryption key. Lives here, not in the eks module,
# because envs/staging is destroyed nightly: a KMS key scheduled for
# deletion keeps its alias allocated for the whole deletion window, so
# tomorrow's `terraform apply` fails trying to recreate
# "alias/${var.project}-eks-secrets", and every nightly teardown would
# accumulate another billable key sitting in PendingDeletion. A key created
# once, here, and referenced by the cluster via var.kms_key_arn has neither
# problem.
resource "aws_kms_key" "eks" {
  description             = "${var.project} EKS Kubernetes Secrets encryption - shared across environments, provisioned here so it survives the nightly staging teardown."
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name = "${var.project}-eks-secrets"
  }
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.project}-eks-secrets"
  target_key_id = aws_kms_key.eks.key_id
}
