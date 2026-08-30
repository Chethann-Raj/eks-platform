terraform {
  # Literal bucket name required: backend "s3" {} blocks cannot interpolate
  # variables or data sources. This must exactly match the bucket created by
  # terraform/bootstrap (see its README for why the name has no account ID).
  backend "s3" {
    bucket       = "chethanraj-eks-platform-tfstate"
    key          = "persistent/terraform.tfstate"
    region       = "ap-south-1"
    use_lockfile = true
  }
}
