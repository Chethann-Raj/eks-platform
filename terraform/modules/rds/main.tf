locals {
  name = "${var.project}-${var.environment}"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # e.g. "16.15" -> "postgres16". Derived from engine_version rather than a
  # separate hardcoded variable, so the two can never disagree with each
  # other if engine_version is bumped later.
  parameter_group_family = "postgres${split(".", var.engine_version)[0]}"
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.name}-rds"
  subnet_ids = var.private_subnet_ids

  tags = merge(local.tags, {
    Name = "${local.name}-rds-subnet-group"
  })
}

# One ingress rule: 5432 from the EKS node/cluster security group only, no
# CIDR-based ingress at all. See README for the caveat on what
# node_security_group_id actually is.
#
# No egress block declared here at all (not even an empty one) - the
# ingress/egress attributes on aws_security_group are independently
# optional+computed, so omitting egress entirely leaves AWS's own
# auto-created "allow all outbound" rule untouched instead of Terraform
# managing (and by omission, deleting) it. There's no specific requirement
# driving restricted egress from this database, so there's no reason to take
# on managing it.
resource "aws_security_group" "rds" {
  name        = "${local.name}-rds"
  description = "Postgres (5432) from EKS nodes only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Postgres from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.node_security_group_id]
  }

  tags = merge(local.tags, {
    Name = "${local.name}-rds"
  })
}

resource "aws_db_parameter_group" "this" {
  name   = "${local.name}-postgres"
  family = local.parameter_group_family

  # shared_preload_libraries is a PGC_POSTMASTER parameter - Postgres only
  # reads it at process start, so changing it can't take effect until the
  # instance reboots. apply_method = "pending-reboot" makes that explicit in
  # the plan instead of Terraform (incorrectly) claiming an immediate apply.
  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  # log_min_duration_statement is a regular runtime-settable parameter -
  # applies immediately (the default apply_method), no reboot needed.
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  tags = merge(local.tags, {
    Name = "${local.name}-postgres-params"
  })
}

resource "aws_db_instance" "this" {
  identifier = "${local.name}-postgres"

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true
  # null falls back to the AWS-managed aws/rds default key.
  kms_key_id = var.kms_key_arn

  db_name  = var.db_name
  username = var.master_username

  # RDS-managed master password: Secrets Manager secret is created and
  # rotated by RDS itself. master_user_secret_kms_key_id is deliberately
  # left unset, so that secret is encrypted with the AWS-managed
  # aws/secretsmanager key, not a customer-managed one - see README.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.this.name

  publicly_accessible = false
  # Single-AZ - see README for the cost trade-off and what changes at
  # production scale.
  multi_az = false

  backup_retention_period = var.backup_retention_period
  skip_final_snapshot     = var.skip_final_snapshot
  # Only meaningful (and only required by AWS) when skip_final_snapshot is
  # false. Fixed name, not timestamped: a timestamp() here would make this
  # attribute (and therefore this resource) show a diff on every single
  # plan. If you destroy-and-recreate more than once with
  # skip_final_snapshot = false, delete or rename the prior snapshot first -
  # see README.
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${local.name}-postgres-final"
  deletion_protection       = var.deletion_protection

  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # Pinned engine_version + auto_minor_version_upgrade both being set is
  # deliberate, not a contradiction: AWS may apply a minor version bump
  # (e.g. 16.15 -> 16.16) automatically during a maintenance window,
  # which is expected to show up as drift on the next `terraform plan`
  # against the pinned var.engine_version. That's an accepted trade-off for
  # automatic security patching - re-pin engine_version to match after a
  # maintenance window if you want the state clean rather than drifted.
  auto_minor_version_upgrade = true

  tags = merge(local.tags, {
    Name = "${local.name}-postgres"
  })
}
