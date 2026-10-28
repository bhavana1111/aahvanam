data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  prefix = "${var.project_name}-${var.environment}"
  azs    = slice(data.aws_availability_zones.available.names, 0, 2)
}

# --------------------------------------------------
# S3: Private invitation image storage
# --------------------------------------------------

resource "aws_s3_bucket" "invitation_images" {
  bucket_prefix = "${local.prefix}-invites-"
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "images" {
  bucket = aws_s3_bucket.invitation_images.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "images" {
  bucket = aws_s3_bucket.invitation_images.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "images" {
  bucket = aws_s3_bucket.invitation_images.id

  versioning_configuration {
    status = "Enabled"
  }
}

# --------------------------------------------------
# IAM: Permissions for the FastAPI backend
# --------------------------------------------------

resource "aws_iam_policy" "backend_runtime" {
  name        = "${local.prefix}-backend-runtime"
  description = "aahvanam backend permissions"

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid    = "InvitationImages"
        Effect = "Allow"

        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ]

        Resource = "${aws_s3_bucket.invitation_images.arn}/invites/*"
      },
      {
        Sid      = "ListInvitationImages"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.invitation_images.arn

        Condition = {
          StringLike = {
            "s3:prefix" = ["invites/*"]
          }
        }
      },
      {
        Sid    = "SendEmail"
        Effect = "Allow"

        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ]

        Resource = "*"
      },
      {
        Sid    = "SendSMS"
        Effect = "Allow"

        Action = [
          "sms-voice:SendTextMessage",
          "sms-voice:DescribePhoneNumbers",
          "sms-voice:DescribeConfigurationSets"
        ]

        Resource = "*"
      }
    ]
  })
}

# --------------------------------------------------
# SES: Optional domain identity
# --------------------------------------------------

resource "aws_ses_domain_identity" "email_domain" {
  count  = var.ses_domain == null ? 0 : 1
  domain = var.ses_domain
}

# --------------------------------------------------
# AWS Budgets: Monthly cost alerts
# --------------------------------------------------

resource "aws_budgets_budget" "monthly_cost" {
  name         = "${local.prefix}-monthly-cost"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}

# --------------------------------------------------
# Optional: Private VPC and RDS PostgreSQL
# --------------------------------------------------

resource "aws_vpc" "app" {
  count                = var.create_rds ? 1 : 0
  cidr_block           = "10.40.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_subnet" "private_db" {
  count = var.create_rds ? 2 : 0

  vpc_id            = aws_vpc.app[0].id
  cidr_block        = count.index == 0 ? "10.40.1.0/24" : "10.40.2.0/24"
  availability_zone = local.azs[count.index]

  map_public_ip_on_launch = false
}

resource "aws_security_group" "backend" {
  count       = var.create_rds ? 1 : 0
  name        = "${local.prefix}-backend"
  description = "Security group for FastAPI backend connectivity"
  vpc_id      = aws_vpc.app[0].id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds" {
  count       = var.create_rds ? 1 : 0
  name        = "${local.prefix}-rds"
  description = "Allow PostgreSQL from the backend security group only"
  vpc_id      = aws_vpc.app[0].id

  ingress {
    description     = "PostgreSQL from FastAPI"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.backend[0].id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_subnet_group" "app" {
  count      = var.create_rds ? 1 : 0
  name       = "${local.prefix}-db-subnets"
  subnet_ids = aws_subnet.private_db[*].id
}

resource "aws_db_instance" "postgres" {
  count = var.create_rds ? 1 : 0

  identifier     = "${local.prefix}-postgres"
  engine         = "postgres"
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  port     = 5432

  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.app[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]

  publicly_accessible = false
  multi_az            = false

  backup_retention_period    = 7
  auto_minor_version_upgrade = true

  deletion_protection = var.environment == "prod"
  skip_final_snapshot = var.environment != "prod"

  final_snapshot_identifier = (
    var.environment == "prod"
    ? "${local.prefix}-postgres-final"
    : null
  )

  copy_tags_to_snapshot = true
}

# --------------------------------------------------
# Additional networking for App Runner and RDS
# --------------------------------------------------

resource "aws_internet_gateway" "app" {
  count  = var.create_rds ? 1 : 0
  vpc_id = aws_vpc.app[0].id
}

resource "aws_subnet" "public" {
  count = var.create_rds ? 2 : 0

  vpc_id                  = aws_vpc.app[0].id
  cidr_block              = count.index == 0 ? "10.40.3.0/24" : "10.40.4.0/24"
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
}

resource "aws_subnet" "private_app" {
  count = var.create_rds ? 2 : 0

  vpc_id            = aws_vpc.app[0].id
  cidr_block        = count.index == 0 ? "10.40.11.0/24" : "10.40.12.0/24"
  availability_zone = local.azs[count.index]
}

resource "aws_route_table" "public" {
  count  = var.create_rds ? 1 : 0
  vpc_id = aws_vpc.app[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.app[0].id
  }
}

resource "aws_route_table_association" "public" {
  count          = var.create_rds ? 2 : 0
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_eip" "nat" {
  count  = var.create_rds ? 1 : 0
  domain = "vpc"

  depends_on = [aws_internet_gateway.app]
}

resource "aws_nat_gateway" "app" {
  count         = var.create_rds ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.app]
}

resource "aws_route_table" "private_app" {
  count  = var.create_rds ? 1 : 0
  vpc_id = aws_vpc.app[0].id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.app[0].id
  }
}

resource "aws_route_table_association" "private_app" {
  count          = var.create_rds ? 2 : 0
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app[0].id
}

# App Runner outbound connector to private resources.
resource "aws_apprunner_vpc_connector" "backend" {
  count = var.create_rds ? 1 : 0

  vpc_connector_name = "${local.prefix}-connector"
  subnets            = aws_subnet.private_app[*].id
  security_groups    = [aws_security_group.backend[0].id]
}

# --------------------------------------------------
# GitHub OIDC and Amazon ECR
# --------------------------------------------------

locals {
  github_configured = (
    var.github_owner != "" &&
    var.github_repo != ""
  )
}

resource "aws_ecr_repository" "backend" {
  count = local.github_configured ? 1 : 0

  name                 = "${local.prefix}-backend"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_iam_openid_connect_provider" "github" {
  count = local.github_configured ? 1 : 0

  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  # Verify this thumbprint against current AWS/GitHub guidance
  # before applying if you are setting up OIDC for the first time.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1"
  ]
}

resource "aws_iam_role" "github_actions" {
  count = local.github_configured ? 1 : 0

  name = "${local.prefix}-github-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github[0].arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"

      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }

        StringLike = {
          "token.actions.githubusercontent.com:sub" = (
            "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/${var.github_branch}"
          )
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_ecr_push" {
  count = local.github_configured ? 1 : 0

  name = "${local.prefix}-github-ecr-push"
  role = aws_iam_role.github_actions[0].id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"

        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage"
        ]

        Resource = aws_ecr_repository.backend[0].arn
      }
    ]
  })
}

# --------------------------------------------------
# App Runner: permission to pull images from ECR
# --------------------------------------------------

resource "aws_iam_role" "apprunner_ecr_access" {
  count = (
    local.github_configured && var.create_app_runner && var.create_rds
  ) ? 1 : 0

  name = "${local.prefix}-apprunner-ecr-access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "build.apprunner.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "apprunner_ecr_access" {
  count = (
    local.github_configured && var.create_app_runner && var.create_rds
  ) ? 1 : 0

  role = aws_iam_role.apprunner_ecr_access[0].name

  policy_arn = (
    "arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess"
  )
}

# --------------------------------------------------
# App Runner: application runtime identity
# --------------------------------------------------

resource "aws_iam_role" "backend_runtime" {
  count = (
    local.github_configured && var.create_app_runner && var.create_rds
  ) ? 1 : 0

  name = "${local.prefix}-backend-runtime-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "tasks.apprunner.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "backend_runtime" {
  count = (
    local.github_configured && var.create_app_runner && var.create_rds
  ) ? 1 : 0

  role       = aws_iam_role.backend_runtime[0].name
  policy_arn = aws_iam_policy.backend_runtime.arn
}

resource "aws_iam_role_policy" "backend_database_secret" {
  count = (
    local.github_configured && var.create_app_runner && var.create_rds
  ) ? 1 : 0

  name = "${local.prefix}-database-secret-read"
  role = aws_iam_role.backend_runtime[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]

      Resource = (
        aws_db_instance.postgres[0].master_user_secret[0].secret_arn
      )
    }]
  })
}

# --------------------------------------------------
# App Runner: automatically deploy the ECR image
# --------------------------------------------------

resource "aws_apprunner_service" "backend" {
  count = (
    local.github_configured && var.create_app_runner && var.create_rds
  ) ? 1 : 0

  service_name = "${local.prefix}-api"

  source_configuration {
    auto_deployments_enabled = true

    authentication_configuration {
      access_role_arn = (
        aws_iam_role.apprunner_ecr_access[0].arn
      )
    }

    image_repository {
      image_identifier = (
        "${aws_ecr_repository.backend[0].repository_url}:latest"
      )

      image_repository_type = "ECR"

      image_configuration {
        port = "8000"

        runtime_environment_variables = {
          DB_HOST = aws_db_instance.postgres[0].address
          DB_PORT = "5432"
          DB_NAME = var.db_name
          DB_SECRET_ARN = (
            aws_db_instance.postgres[0].master_user_secret[0].secret_arn
          )
        }
      }
    }
  }

  instance_configuration {
    cpu               = "0.25 vCPU"
    memory            = "0.5 GB"
    instance_role_arn = aws_iam_role.backend_runtime[0].arn
  }

  network_configuration {
    egress_configuration {
      egress_type = "VPC"

      vpc_connector_arn = (
        aws_apprunner_vpc_connector.backend[0].arn
      )
    }

    ingress_configuration {
      is_publicly_accessible = true
    }
  }

  health_check_configuration {
    protocol = "HTTP"
    path     = "/health"
  }

  depends_on = [
    aws_iam_role_policy_attachment.apprunner_ecr_access,
    aws_iam_role_policy_attachment.backend_runtime,
    aws_iam_role_policy.backend_database_secret
  ]
}