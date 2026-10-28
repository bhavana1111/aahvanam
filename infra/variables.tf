variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "aahvanam"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "budget_alert_email" {
  description = "Email address for AWS budget notifications"
  type        = string
}

variable "budget_limit_usd" {
  type    = number
  default = 25
}

variable "create_rds" {
  description = "Create private RDS PostgreSQL and VPC networking"
  type        = bool
  default     = false
}

variable "db_name" {
  type    = string
  default = "aahvanam"
}

variable "db_username" {
  type    = string
  default = "aahvanam_admin"
}

variable "db_instance_class" {
  description = "Check regional availability and pricing"
  type        = string
  default     = "db.t4g.micro"
}

variable "ses_domain" {
  description = "Optional domain for SES verification"
  type        = string
  default     = null
}

variable "create_sqs" {
  description = "Enable notification queue for future background processing"
  type        = bool
  default     = false
}

variable "github_owner" {
  description = "GitHub account or organization that owns the monorepo"
  type        = string
  default     = ""
}

variable "github_repo" {
  description = "GitHub monorepo name"
  type        = string
  default     = ""
}

variable "github_branch" {
  description = "Branch that triggers backend deployment"
  type        = string
  default     = "main"
}

variable "create_app_runner" {
  description = "Create App Runner after the first backend image exists in ECR"
  type        = bool
  default     = false
}