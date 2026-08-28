variable "aws_region" {
  default = "us-east-1"
}

variable "project_name" {
  default = "eks-cicd-demo"
}

variable "github_repo" {
  description = "format: your-username/eks-cicd-demo"
  type        = string
}
