output "aws_region" {
  value = var.aws_region
}

output "s3_bucket_name" {
  description = "Private bucket for invitation images"
  value       = aws_s3_bucket.invitation_images.bucket
}

output "backend_runtime_policy_arn" {
  description = "IAM policy ARN for the FastAPI runtime role"
  value       = aws_iam_policy.backend_runtime.arn
}

output "ses_domain_verification_token" {
  value = try(
    aws_ses_domain_identity.email_domain[0].verification_token,
    null
  )
}

output "vpc_id" {
  value = try(aws_vpc.app[0].id, null)
}

output "backend_security_group_id" {
  value = try(aws_security_group.backend[0].id, null)
}

output "rds_endpoint" {
  description = "Private RDS PostgreSQL endpoint"
  value       = try(aws_db_instance.postgres[0].address, null)
}

output "rds_master_secret_arn" {
  description = "RDS-managed master credentials secret ARN"
  value = try(
    aws_db_instance.postgres[0].master_user_secret[0].secret_arn,
    null
  )
}
output "ecr_repository_url" {
  value = try(aws_ecr_repository.backend[0].repository_url, null)
}

output "github_actions_role_arn" {
  value = try(aws_iam_role.github_actions[0].arn, null)
}

output "apprunner_service_url" {
  value = try(aws_apprunner_service.backend[0].service_url, null)
}