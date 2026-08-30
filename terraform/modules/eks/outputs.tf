output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_arn" {
  value = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  value = aws_eks_cluster.this.version
}

# The RDS module needs this for its 5432 ingress rule: with no custom
# launch_template, this is the security group EKS attaches to every node in
# aws_eks_node_group.default (as well as to the control plane ENIs).
output "node_security_group_id" {
  description = "Security group ID attached to nodes - use this for the RDS 5432 ingress rule."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  value = aws_iam_openid_connect_provider.eks.url
}

output "node_group_name" {
  value = aws_eks_node_group.default.node_group_name
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}
