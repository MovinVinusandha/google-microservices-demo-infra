module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.25.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_private_access = true
  endpoint_public_access  = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]
  cloudwatch_log_group_retention_in_days = var.log_retention_days

  create_kms_key                  = true
  kms_key_description             = "EKS Secrets KMS Key for ${var.cluster_name}"
  kms_key_enable_default_policy   = true
  kms_key_deletion_window_in_days = 30
  encryption_config = {
    resources = ["secrets"]
  }

  compute_config = {
    enabled    = true
    node_pools = var.eks_node_pools
  }

  enable_cluster_creator_admin_permissions = false

  access_entries = {
    bootstrap_deployer = {
      principal_arn = data.aws_caller_identity.current.arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  tags = var.tags
}

data "aws_caller_identity" "current" {}