output "ecr_repo_url" {
  value = aws_ecr_repository.app.repository_url
}

output "github_connection_arn" {
  value       = aws_codestarconnections_connection.github.arn
  description = "You must approve this connection in the AWS Console before the pipeline works — see Step 5 in the guide."
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}
