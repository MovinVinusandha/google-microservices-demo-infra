resource "aws_secretsmanager_secret" "app_secrets" {
  name                    = "${var.cluster_name}/${var.environment}/app"
  description             = "Application secrets for ${var.environment} managed outside Terraform"
  recovery_window_in_days = 0

  tags = var.tags
}

resource "aws_iam_policy" "external_secrets" {
  name        = "${var.cluster_name}-external-secrets-policy"
  description = "Allows External Secrets Operator to fetch secrets from AWS Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:ListSecretVersionIds"
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.cluster_name}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role" "external_secrets" {
  name = "${var.cluster_name}-external-secrets-role"

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

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "external_secrets" {
  role       = aws_iam_role.external_secrets.name
  policy_arn = aws_iam_policy.external_secrets.arn
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets-sa"
  role_arn        = aws_iam_role.external_secrets.arn
}
