terraform {
  # Literal bucket name required: backend "s3" {} blocks cannot interpolate
  # variables or data sources. Must exactly match the bucket created by
  # terraform/bootstrap.
  backend "s3" {
    bucket       = "chethanraj-eks-platform-tfstate"
    key          = "envs/staging/terraform.tfstate"
    region       = "ap-south-1"
    use_lockfile = true
    encrypt      = true
  }
}
