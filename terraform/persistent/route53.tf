# Stable for the life of the project. Destroying and recreating this zone
# issues new NS records, breaking Namecheap delegation every rebuild - this
# is why it lives in the persistent layer, not envs/staging.
resource "aws_route53_zone" "primary" {
  name = var.domain_name
}
