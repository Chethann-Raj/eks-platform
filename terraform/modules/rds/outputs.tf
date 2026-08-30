output "endpoint" {
  description = "Connection endpoint (host:port)."
  value       = aws_db_instance.this.endpoint
}

output "port" {
  value = aws_db_instance.this.port
}

output "db_name" {
  value = aws_db_instance.this.db_name
}

output "security_group_id" {
  description = "The RDS security group's own ID, in case something else needs to be granted access to it."
  value       = aws_security_group.rds.id
}

# The password itself is never output. RDS-managed master password support
# (manage_master_user_password) means there is no plaintext password in this
# module, in state, or in any Terraform output to begin with - only this
# ARN, which points at the RDS-created and RDS-rotated Secrets Manager
# secret. Consumers (e.g. ESO in Phase 2) read the secret via this ARN.
output "master_user_secret_arn" {
  description = "Secrets Manager ARN of the RDS-managed master user secret. Never the password itself."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}
