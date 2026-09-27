resource "aws_iam_role" "cloudwatch_observability" {
  name = "${var.cluster_name}-cloudwatch-observability-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
    }]
  })

  tags = {
    Environment = "production"
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.cloudwatch_observability.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "xray" {
  role       = aws_iam_role.cloudwatch_observability.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess"
}

resource "aws_eks_pod_identity_association" "cloudwatch_observability" {
  cluster_name    = module.eks.cluster_name
  namespace       = "amazon-cloudwatch"
  service_account = "cloudwatch-agent"
  role_arn        = aws_iam_role.cloudwatch_observability.arn
}

resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "amazon-cloudwatch-observability"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_pod_identity_association.cloudwatch_observability
  ]

  tags = var.tags
}
