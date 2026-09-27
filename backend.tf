terraform {
  backend "s3" {
    bucket       = "mycompany-prod-terraform-state-878311410498"
    key          = "eks/production/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}