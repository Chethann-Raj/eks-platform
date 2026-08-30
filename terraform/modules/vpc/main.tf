locals {
  name = "${var.project}-${var.environment}"

  # Local Zones/Wavelength Zones require separate opt-in and aren't returned
  # by this data source by default, so this is already just the 2 standard
  # AZs for the region - deterministic ordering via sort() so the AZ that
  # gets index [0] (and therefore the NAT gateway) doesn't change between
  # plans.
  azs = slice(sort(data.aws_availability_zones.available.names), 0, 2)

  public_subnets_by_az  = { for idx, az in local.azs : az => { cidr = var.public_subnet_cidrs[idx] } }
  private_subnets_by_az = { for idx, az in local.azs : az => { cidr = var.private_subnet_cidrs[idx] } }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name}-igw"
  }
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets_by_az

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = merge(
    {
      Name                     = "${local.name}-public-${each.key}"
      "kubernetes.io/role/elb" = "1"
    },
    var.public_subnet_tags,
  )
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets_by_az

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.key

  tags = merge(
    {
      Name                              = "${local.name}-private-${each.key}"
      "kubernetes.io/role/internal-elb" = "1"
    },
    var.private_subnet_tags,
  )
}

# Single NAT Gateway shared across both AZs - deliberate cost trade-off
# (~$32/mo saved vs. one per AZ) at the cost of an AZ-level SPOF for egress
# from private subnets. See CLAUDE.md §7 and the root README for the
# reasoning. Placed in the first (deterministically-sorted) public subnet.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.name}-nat-eip"
  }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[local.azs[0]].id

  tags = {
    Name = "${local.name}-nat"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name}-public-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# One route table per AZ, even though both currently carry an identical
# 0.0.0.0/0 -> the single shared NAT Gateway route. Behaviour today is the
# same as one shared table, but Phase 5 documents fck-nat per-AZ as the next
# cost optimisation - that means each AZ getting its own NAT instance/device,
# which requires each AZ to already have its own route table to point at a
# different target. Splitting now makes that later change a per-table route
# swap instead of a route-table restructure.
resource "aws_route_table" "private" {
  for_each = toset(local.azs)

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${local.name}-private-rt-${each.key}"
  }
}

resource "aws_route" "private_nat" {
  for_each = aws_route_table.private

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# Gateway VPC endpoint for S3 - no hourly or per-GB charge, unlike the NAT
# Gateway's $0.045/GB. Loki (Phase 4) writes to S3 continuously from pods in
# the private subnets; without this endpoint every one of those PUTs
# traverses the NAT Gateway and is billed as NAT data processing for traffic
# that never needed to leave AWS's network in the first place. Associated
# with every route table (public and both private) since it's free to attach
# broadly and any subnet may end up talking to S3 (e.g. ECR image layer
# pulls, which are backed by S3).
#
# Deliberately NOT adding Interface endpoints for anything else: those cost
# ~$0.01/hr *per AZ* regardless of traffic, which on a cluster that's
# destroyed and rebuilt nightly can easily cost more than the NAT traffic
# they'd offload. See the module README for the trade-off.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    [aws_route_table.public.id],
    [for rt in aws_route_table.private : rt.id],
  )

  tags = {
    Name = "${local.name}-s3-endpoint"
  }
}
