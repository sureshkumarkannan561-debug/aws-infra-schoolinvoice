variable "github_owner" {
  description = "GitHub organization or user that owns this infrastructure repository."
  type        = string

  validation {
    condition     = length(trimspace(var.github_owner)) > 0
    error_message = "github_owner must not be empty."
  }
}

variable "github_repository" {
  description = "Name of the GitHub repository containing this Terraform configuration."
  type        = string

  validation {
    condition     = length(trimspace(var.github_repository)) > 0
    error_message = "github_repository must not be empty."
  }
}

variable "github_branch" {
  description = "Branch whose changes are planned by the infrastructure pipeline."
  type        = string
  default     = "main"
}

locals {
  terraform_state_key = "${local.name}/terraform.tfstate"
}

resource "aws_s3_bucket" "terraform_state" {
  bucket_prefix = "${local.name}-${data.aws_caller_identity.current.account_id}-tfstate-"

  lifecycle {
    force_destroy = true
  }

  tags = merge(local.common_tags, { Name = "${local.name}-terraform-state" })
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "terraform_locks" {
  name         = "${local.name}-terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = local.common_tags
}

resource "aws_codestarconnections_connection" "github" {
  name          = "${local.name}-infra-github"
  provider_type = "GitHub"

  tags = local.common_tags
}

resource "aws_s3_bucket" "pipeline_artifacts" {
  bucket_prefix = "${local.name}-${data.aws_caller_identity.current.account_id}-pipeline-"

  tags = local.common_tags
}

resource "aws_s3_bucket_versioning" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline_artifacts" {
  bucket = aws_s3_bucket.pipeline_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "pipeline_artifacts" {
  bucket                  = aws_s3_bucket.pipeline_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_role" "codepipeline" {
  name = "${local.name}-codepipeline"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "codepipeline" {
  name = "${local.name}-codepipeline"
  role = aws_iam_role.codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketVersioning",
          "s3:GetBucketAcl",
          "s3:GetBucketLocation",
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.pipeline_artifacts.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:PutObjectAcl"
        ]
        Resource = "${aws_s3_bucket.pipeline_artifacts.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["codestar-connections:UseConnection"]
        Resource = aws_codestarconnections_connection.github.arn
      },
      {
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild",
          "codebuild:BatchGetBuilds"
        ]
        Resource = [
          aws_codebuild_project.plan.arn,
          aws_codebuild_project.apply.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role" "codebuild" {
  name = "${local.name}-terraform-codebuild"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "codebuild_power_user" {
  role       = aws_iam_role.codebuild.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy" "codebuild_state_and_iam" {
  name = "${local.name}-terraform-state-and-iam"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${local.name}-terraform-*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:ListBucket",
          "s3:GetBucketVersioning"
        ]
        Resource = [
          aws_s3_bucket.terraform_state.arn,
          aws_s3_bucket.pipeline_artifacts.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "${aws_s3_bucket.terraform_state.arn}/${local.name}/*",
          "${aws_s3_bucket.pipeline_artifacts.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeTable",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem"
        ]
        Resource = aws_dynamodb_table.terraform_locks.arn
      },
      {
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:PassRole"
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.name}-*"
      },
      {
        Effect = "Allow"
        Action = [
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:ListPolicies",
          "iam:ListPolicyVersions",
          "iam:ListRoles"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = [
              "rds.amazonaws.com",
              "elasticloadbalancing.amazonaws.com",
              "ecs.amazonaws.com"
            ]
          }
        }
      }
    ]
  })
}

resource "aws_codebuild_project" "plan" {
  name         = "${local.name}-terraform-plan"
  description  = "Validate and plan Terraform infrastructure changes."
  service_role = aws_iam_role.codebuild.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "AWS_REGION"
      value = var.aws_region
    }

    environment_variable {
      name  = "TF_STATE_BUCKET"
      value = aws_s3_bucket.terraform_state.bucket
    }

    environment_variable {
      name  = "TF_STATE_KEY"
      value = local.terraform_state_key
    }

    environment_variable {
      name  = "TF_LOCK_TABLE"
      value = aws_dynamodb_table.terraform_locks.name
    }
  }

  logs_config {
    cloudwatch_logs {
      status = "ENABLED"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec-plan.yml"
  }

  tags = local.common_tags
}

resource "aws_codebuild_project" "apply" {
  name         = "${local.name}-terraform-apply"
  description  = "Apply the approved Terraform plan."
  service_role = aws_iam_role.codebuild.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "AWS_REGION"
      value = var.aws_region
    }

    environment_variable {
      name  = "TF_STATE_BUCKET"
      value = aws_s3_bucket.terraform_state.bucket
    }

    environment_variable {
      name  = "TF_STATE_KEY"
      value = local.terraform_state_key
    }

    environment_variable {
      name  = "TF_LOCK_TABLE"
      value = aws_dynamodb_table.terraform_locks.name
    }
  }

  logs_config {
    cloudwatch_logs {
      status = "ENABLED"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec-apply.yml"
  }

  tags = local.common_tags
}

resource "aws_codepipeline" "infrastructure" {
  name     = "${local.name}-infrastructure"
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.pipeline_artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "GitHub"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["SourceArtifact"]

      configuration = {
        ConnectionArn        = aws_codestarconnections_connection.github.arn
        FullRepositoryId     = "${var.github_owner}/${var.github_repository}"
        BranchName           = var.github_branch
        DetectChanges        = "true"
        OutputArtifactFormat = "CODE_ZIP"
      }
    }
  }

  stage {
    name = "Plan"

    action {
      name             = "TerraformPlan"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["SourceArtifact"]
      output_artifacts = ["PlanArtifact"]

      configuration = {
        ProjectName = aws_codebuild_project.plan.name
      }
    }
  }

  stage {
    name = "Approval"

    action {
      name     = "ApproveTerraformChanges"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"

      configuration = {
        CustomData = "Review the Terraform plan in the Plan action logs before approving."
      }
    }
  }

  stage {
    name = "Apply"

    action {
      name            = "TerraformApply"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["SourceArtifact", "PlanArtifact"]

      configuration = {
        ProjectName   = aws_codebuild_project.apply.name
        PrimarySource = "SourceArtifact"
      }
    }
  }

  tags = local.common_tags
}

output "codepipeline_name" {
  description = "CodePipeline that plans and applies Terraform from the configured GitHub branch."
  value       = aws_codepipeline.infrastructure.name
}

output "github_connection_arn" {
  description = "Complete this pending GitHub connection in the AWS console before enabling pipeline runs."
  value       = aws_codestarconnections_connection.github.arn
}

output "terraform_state_bucket" {
  description = "S3 bucket used for encrypted, versioned Terraform state."
  value       = aws_s3_bucket.terraform_state.bucket
}

output "terraform_lock_table" {
  description = "DynamoDB table used to lock Terraform state operations."
  value       = aws_dynamodb_table.terraform_locks.name
}