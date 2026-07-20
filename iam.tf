# IRSA trust policies are derived from the resolved OIDC provider ARN rather
# than a hand-assembled string — a malformed ARN here fails at plan time
# instead of surfacing later as a broken service account.
data "aws_iam_openid_connect_provider" "eks" {
  url = module.eks.cluster_oidc_issuer_url
}

# EBS CSI driver role
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "eoapi-tf-ebs-csi-role"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = data.aws_iam_openid_connect_provider.eks.arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# AWS Load Balancer Controller role
module "alb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "eoapi-tf-alb-controller-role"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = data.aws_iam_openid_connect_provider.eks.arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

# eoAPI application role: the raster service reads Cloud-Optimized GeoTIFFs
# straight from S3 at request time, so the app pods themselves need AWS
# permissions. Same IRSA pattern as the controllers above, applied to the
# application's service account rather than an infrastructure add-on — the AWS
# credential chain then supplies the pod temporary credentials with no static
# keys anywhere.
resource "aws_iam_policy" "eoapi_s3_read" {
  name        = "eoapi-tf-s3-read"
  description = "Read-only access to the S3 buckets holding eoAPI source imagery (COGs)."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListImageryBuckets"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = var.eoapi_s3_bucket_arns
      },
      {
        Sid      = "ReadImageryObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = [for arn in var.eoapi_s3_bucket_arns : "${arn}/*"]
      }
    ]
  })
}

module "eoapi_app_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "eoapi-tf-app-role"

  role_policy_arns = {
    s3_read = aws_iam_policy.eoapi_s3_read.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = data.aws_iam_openid_connect_provider.eks.arn
      namespace_service_accounts = ["${var.eoapi_namespace}:${var.eoapi_service_account_name}"]
    }
  }
}
