# Remote state in S3 with NATIVE S3 locking (use_lockfile). No DynamoDB table.
# Fill in your bucket, or pass it at init: terraform init -backend-config=...
terraform {
  backend "s3" {
    bucket       = "REPLACE_WITH_YOUR_TFSTATE_BUCKET"
    key          = "cicd-ecs/shared/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true # S3-native state locking (Terraform >= 1.10)
  }
}
