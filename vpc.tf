provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.2"

  name = "${var.cluster_name}-vpc"
  cidr = var.cidr_block

  azs             = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true
  enable_dns_hostnames   = true
  enable_dns_support     = true

  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_cloudwatch_log_group_retention_in_days = var.log_retention_days
  flow_log_max_aggregation_interval               = 60

  tags = merge(var.tags, {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })

  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
    "karpenter.sh/discovery"                    = var.cluster_name
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id          = module.vpc.vpc_id
  service_name    = "com.amazonaws.${var.aws_region}.s3"
  route_table_ids = module.vpc.private_route_table_ids

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-s3-endpoint"
  })
}