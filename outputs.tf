output "region_azs" {
  description = "The availability zones in the AWS region"
  value       = data.aws_availability_zones.available.names
}

output "bastion_instance_id" {
  description = "The EC2 Instance ID of the single Bastion"
  value       = aws_instance.bastion.id
}

output "eks_api_server_domain" {
  description = "Domain of the private EKS endpoint for SSM tunneling"
  value       = replace(module.eks.cluster_endpoint, "https://", "")
}

output "connect_script" {
  description = "Clean SSM port forwarding command"
  value       = <<-EOT
aws ssm start-session --target ${aws_instance.bastion.id} --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters '{"host":["${replace(module.eks.cluster_endpoint, "https://", "")}"],"portNumber":["443"],"localPortNumber":["6443"]}'
EOT
}

output "route53_name_servers" {
  description = "COPY THESE 4 NAME SERVERS INTO YOUR EXTERNAL DOMAIN REGISTRAR"
  value       = aws_route53_zone.primary.name_servers
}

output "acm_certificate_arn" {
  description = "ARN of the validated ACM Certificate"
  value       = aws_acm_certificate.cert.arn
}

output "github_actions_role_arn" {
  description = "IAM Role ARN to configure in GitHub Actions (role-to-assume)"
  value       = aws_iam_role.github_actions.arn
}

output "secrets_manager_secret_name" {
  description = "Path to the secret in AWS Secrets Manager"
  value       = aws_secretsmanager_secret.app_secrets.name
}