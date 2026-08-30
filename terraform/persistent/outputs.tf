output "hosted_zone_id" {
  description = "Route53 hosted zone ID for chethanraj.site."
  value       = aws_route53_zone.primary.zone_id
}

output "hosted_zone_name_servers" {
  description = "Nameservers to configure at Namecheap for delegation."
  value       = aws_route53_zone.primary.name_servers
}

output "acm_certificate_arn" {
  description = "ARN of the validated wildcard certificate (chethanraj.site + *.chethanraj.site)."
  value       = aws_acm_certificate_validation.wildcard.certificate_arn
}

output "ecr_repository_url" {
  description = "ECR repository URL the CI pipeline pushes images to."
  value       = aws_ecr_repository.app.repository_url
}

output "github_oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN."
  value       = aws_iam_openid_connect_provider.github_actions.arn
}

output "ci_deploy_role_arn" {
  description = "Role assumed by main.yml (push to main) to deploy to staging."
  value       = aws_iam_role.ci_deploy.arn
}

output "ci_production_role_arn" {
  description = "Role assumed by prod.yml (workflow_dispatch, production environment)."
  value       = aws_iam_role.ci_production.arn
}

output "eks_kms_key_arn" {
  description = "KMS key ARN for EKS Kubernetes Secrets encryption - pass to the eks module's kms_key_arn variable. IRREVERSIBLE: never schedule this key for deletion while any cluster's encryption_config still references it. Doing so permanently breaks decryption of every Kubernetes Secret encrypted with it, with no recovery path once the deletion window elapses."
  value       = aws_kms_key.eks.arn
}
