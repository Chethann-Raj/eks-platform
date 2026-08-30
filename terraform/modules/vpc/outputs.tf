output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "VPC CIDR block."
  value       = aws_vpc.this.cidr_block
}

output "availability_zones" {
  description = "The 2 AZs subnets were created in, in the same order used to index the CIDR variables."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB, NAT), ordered to match availability_zones."
  value       = [for az in local.azs : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  description = "Private subnet IDs (nodes, RDS), ordered to match availability_zones."
  value       = [for az in local.azs : aws_subnet.private[az].id]
}

output "public_route_table_id" {
  description = "Public route table ID."
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "Private route table IDs, one per AZ, ordered to match availability_zones."
  value       = [for az in local.azs : aws_route_table.private[az].id]
}

output "nat_gateway_id" {
  description = "NAT Gateway ID (single, shared across both AZs)."
  value       = aws_nat_gateway.this.id
}

output "nat_gateway_public_ip" {
  description = "Elastic IP address of the shared NAT Gateway."
  value       = aws_eip.nat.public_ip
}

output "flow_log_group_name" {
  description = "CloudWatch Logs group name receiving VPC Flow Logs."
  value       = aws_cloudwatch_log_group.vpc_flow_log.name
}
