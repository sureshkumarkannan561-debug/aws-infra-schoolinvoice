# SchoolInvoice AWS Infrastructure

This repository contains the Terraform configuration for AWS infrastructure and a GitHub-triggered CodePipeline that runs Terraform only. It does not build or deploy the Spring Boot or Angular applications; those can live in separate repositories and use separate pipelines later.

The pipeline runs `terraform init`, `validate`, and `plan`, pauses for manual approval, then applies the exact saved plan. Terraform state is stored in a versioned, encrypted S3 bucket and locked with DynamoDB.

## Configure the GitHub repository

1. Push this repository to GitHub. Keep Terraform configuration and the `buildspec-*.yml` files at the repository root.
2. Create `terraform.tfvars` from `terraform.tfvars.example` and set the GitHub owner and infrastructure repository name. These values are configuration, not credentials; do not put secrets in this file. Commit the completed file so CodeBuild receives the same inputs.
3. Configure AWS credentials locally with permission to create the infrastructure, state bucket, lock table, IAM roles, CodeStar connection, and pipeline.

## Bootstrap once

The remote state bucket is itself created by this Terraform configuration, so the first apply must use local state. Run these commands in PowerShell from the repository directory:

```powershell
terraform init -backend=false
terraform validate
terraform plan
terraform apply
```

After apply succeeds, migrate the local state into the newly created S3 backend:

```powershell
$StateBucket = terraform output -raw terraform_state_bucket
$LockTable = terraform output -raw terraform_lock_table
terraform init -migrate-state -backend-config="bucket=$StateBucket" -backend-config="key=schoolinvoice/terraform.tfstate" -backend-config="region=ap-south-1" -backend-config="dynamodb_table=$LockTable" -backend-config="encrypt=true"
```

Use the same `key` and `region` values as the CodeBuild configuration if you change them. Confirm Terraform's state migration prompt. Do not delete the local state file until migration is complete and verified.

## Connect GitHub and run

1. In the AWS Console, open **Developer Tools > Connections**, select the connection shown by the `github_connection_arn` output, and complete GitHub authorization for this infrastructure repository.
2. Wait for the connection status to become `AVAILABLE`. The first pipeline run starts from the configured branch; later commits trigger new runs.
3. Review the Terraform plan in the CodeBuild plan action logs. Approve the CodePipeline manual approval action to apply it, or reject it to stop the run.

The CodeBuild role uses AWS `PowerUserAccess` plus scoped IAM permissions because Terraform manages multiple AWS service types and creates application roles. Treat this role and the GitHub branch as privileged; restrict repository write access and approval permissions. The plan artifact can contain sensitive values, so restrict access to CodePipeline, CodeBuild logs, and the artifact bucket.

## Notes

The infrastructure includes chargeable resources such as a NAT Gateway, RDS, an Application Load Balancer, and CloudFront. The Terraform state bucket has deletion protection and should be retained. Review changes in every plan before approving them.