# authentication_mode = "API" (set in main.tf) - the aws-auth ConfigMap is
# deprecated. Every principal that needs cluster access is declared through
# var.access_entries by the caller; this module has no hardcoded ARNs of
# its own.
resource "aws_eks_access_entry" "this" {
  for_each = var.access_entries

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn
}

resource "aws_eks_access_policy_association" "this" {
  for_each = var.access_entries

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value.principal_arn

  # EKS cluster access policies are a DISTINCT ARN namespace from IAM
  # policies - arn:aws:eks::aws:cluster-access-policy/<name>, never
  # arn:aws:iam::aws:policy/<name>. Both are syntactically valid ARNs, so a
  # policy name accidentally built into the IAM namespace passes
  # `terraform validate` and even `terraform plan` without complaint -
  # it only fails at apply, against the real EKS API, with
  # InvalidParameterException: "The policyArn parameter format is not
  # valid". Confirm valid names with `aws eks list-access-policies`; never
  # guess or reuse an IAM-looking ARN here.
  policy_arn = "arn:aws:eks::aws:cluster-access-policy/${each.value.access_policy}"

  access_scope {
    type       = each.value.access_scope_type
    namespaces = each.value.access_scope_type == "namespace" ? each.value.namespaces : null
  }

  depends_on = [aws_eks_access_entry.this]
}
