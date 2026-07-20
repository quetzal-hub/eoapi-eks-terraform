output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint URL of the EKS control plane."
  value       = module.eks.cluster_endpoint
}

output "region" {
  description = "AWS region the stack is deployed in."
  value       = var.aws_region
}

output "vpc_id" {
  description = "ID of the VPC hosting the cluster."
  value       = module.vpc.vpc_id
}

output "ebs_csi_role_arn" {
  description = "IAM role ARN used by the EBS CSI driver (IRSA)."
  value       = module.ebs_csi_irsa.iam_role_arn
}

output "alb_controller_role_arn" {
  description = "IAM role ARN used by the AWS Load Balancer Controller (IRSA)."
  value       = module.alb_controller_irsa.iam_role_arn
}

output "eoapi_app_role_arn" {
  description = "IAM role ARN the eoAPI services assume for S3 access (IRSA)."
  value       = module.eoapi_app_irsa.iam_role_arn
}

output "configure_kubectl" {
  description = "Command to point kubectl at the new cluster."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
