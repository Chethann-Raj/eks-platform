output "state_bucket_name" {
  description = "S3 bucket name to reference in every other layer's backend \"s3\" block."
  value       = aws_s3_bucket.tfstate.id
}

output "state_bucket_arn" {
  description = "ARN of the Terraform state bucket."
  value       = aws_s3_bucket.tfstate.arn
}

output "aws_region" {
  description = "Region the state bucket lives in, for backend config convenience."
  value       = var.aws_region
}
