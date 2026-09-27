# GENERAL & ENVIRONMENT
variable "aws_region" {
  description = "The AWS region to deploy resources into."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "The deployment environment (e.g. production, staging, dev)."
  type        = string
  default     = "production"
}

variable "cluster_name" {
  description = "The name of the EKS cluster and base name for associated resources."
  type        = string
  default     = "prod-eks-cluster"
}

variable "tags" {
  description = "Common tags applied to all provisioned resources."
  type        = map(string)
  default = {
    Environment = "production"
    ManagedBy   = "Terraform"
    Project     = "enterprise-eks"
  }
}

# NETWORKING (VPC)
variable "cidr_block" {
  description = "The CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to use (2 or 3)."
  type        = number
  default     = 2
}

variable "private_subnets" {
  description = "List of private subnet CIDR blocks."
  type        = list(string)
  default     = ["10.0.0.0/20", "10.0.16.0/20"]
}

variable "public_subnets" {
  description = "List of public subnet CIDR blocks."
  type        = list(string)
  default     = ["10.0.128.0/24", "10.0.129.0/24"]
}

# EKS CLUSTER
variable "kubernetes_version" {
  description = "Kubernetes control plane version."
  type        = string
  default     = "1.36"
}

variable "eks_node_pools" {
  description = "Node pools enabled for EKS Auto Mode."
  type        = list(string)
  default     = ["general-purpose", "system"]
}

variable "log_retention_days" {
  description = "Retention period in days for CloudWatch Log Groups (Flow logs & EKS audit logs)."
  type        = number
  default     = 90
}

# BASTION HOST
variable "bastion_instance_type" {
  description = "EC2 instance type for the SSM Bastion host."
  type        = string
  default     = "t3.micro"
}

variable "bastion_volume_size" {
  description = "Root disk volume size (in GB) for the Bastion."
  type        = number
  default     = 10
}

# DOMAIN & INGRESS (ROUTE 53 & ACM)
variable "domain_name" {
  description = "The primary domain name managed in Route 53 (e.g. example.me)."
  type        = string
  default     = "example.me"
}

# CI/CD & ECR
variable "ecr_repository_name" {
  description = "Name of the Amazon ECR repository for container images."
  type        = string
  default     = "my-app"
}

variable "ecr_image_retention_count" {
  description = "Maximum number of container images to keep in ECR before expiring."
  type        = number
  default     = 30
}

variable "github_repository" {
  description = "The GitHub repository allowed to assume the OIDC role (format: 'owner/repo' or 'owner/*')."
  type        = string
  default     = "example-repo/*"
}