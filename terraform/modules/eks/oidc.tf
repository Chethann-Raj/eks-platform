# IRSA (IAM Roles for Service Accounts): lets pods (e.g. the EBS CSI
# controller in addons.tf) assume an IAM role scoped to their own service
# account, instead of the node role's permissions being available to every
# pod on the node.
data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}
