# ---------------------------------------------------------------------------
# General
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-west-2"
}

variable "tags" {
  description = "Tags applied to every AWS resource via provider default_tags."
  type        = map(string)
  default = {
    Project   = "eoapi-eks-terraform"
    ManagedBy = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "vpc_name" {
  description = "Name of the VPC."
  type        = string
  default     = "eoapi-vpc"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones to spread subnets across (EKS requires at least two)."
  type        = list(string)
  default     = ["us-west-2a", "us-west-2b"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the private subnets (one per availability zone)."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets (one per availability zone)."
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

variable "single_nat_gateway" {
  description = "Use a single shared NAT gateway (cheaper) instead of one per AZ (more resilient)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# EKS cluster
# ---------------------------------------------------------------------------

variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
  default     = "eoapi-tf-cluster"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS control plane."
  type        = string
  default     = "1.34"
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_group_min_size" {
  description = "Minimum number of worker nodes."
  type        = number
  default     = 2
}

variable "node_group_max_size" {
  description = "Maximum number of worker nodes."
  type        = number
  default     = 3
}

variable "node_group_desired_size" {
  description = "Desired number of worker nodes."
  type        = number
  default     = 2
}

# ---------------------------------------------------------------------------
# Helm releases
# ---------------------------------------------------------------------------

variable "alb_controller_chart_version" {
  description = "Chart version of the AWS Load Balancer Controller. Must map to controller >= v3.x for native ALB URL rewriting."
  type        = string
  default     = "3.4.2"
}

variable "pgo_chart_version" {
  description = "Chart version of the CrunchyData Postgres operator."
  type        = string
  default     = "5.8.6"
}

variable "eoapi_chart_version" {
  description = "Chart version of the eoAPI Helm chart. Pinned for reproducible deploys."
  type        = string
  default     = "0.13.1"
}

variable "cert_manager_chart_version" {
  description = "Chart version of cert-manager. Empty string tracks the latest release; pin to a tested version for reproducible deploys."
  type        = string
  default     = ""
}

variable "otel_operator_chart_version" {
  description = "Chart version of the OpenTelemetry Operator. Empty string tracks the latest release; pin to a tested version for reproducible deploys."
  type        = string
  default     = ""
}

variable "eoapi_namespace" {
  description = "Kubernetes namespace for the eoAPI release and its observability sidecars."
  type        = string
  default     = "eoapi"
}

variable "eoapi_helm_timeout" {
  description = "Timeout (seconds) for the eoAPI Helm release. Generous because the chart's post-install jobs are slow."
  type        = number
  default     = 1800
}

# ---------------------------------------------------------------------------
# eoAPI application access (IRSA for S3)
# ---------------------------------------------------------------------------

variable "eoapi_service_account_name" {
  description = "Name of the Kubernetes service account the eoAPI services run as. Bound to the app IRSA role so the raster service can read COGs from S3."
  type        = string
  default     = "eoapi-sa"
}

variable "eoapi_s3_bucket_arns" {
  description = "ARNs of the S3 buckets holding source imagery (COGs) the raster service reads. The app IRSA role is granted s3:GetObject on their objects and s3:ListBucket on the buckets. Defaults to the public Sentinel-2 COG bucket used by eoAPI examples; add your own buckets here."
  type        = list(string)
  default     = ["arn:aws:s3:::sentinel-cogs"]
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

variable "jaeger_image" {
  description = "Container image for the Jaeger all-in-one trace backend."
  type        = string
  default     = "jaegertracing/all-in-one:latest"
}
