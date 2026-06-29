# S3 remote state with native locking (use_lockfile). No DynamoDB.
terraform {
  backend "s3" {
    bucket       = "REPLACE_WITH_YOUR_TFSTATE_BUCKET"
    key          = "cicd-ecs/envs/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
