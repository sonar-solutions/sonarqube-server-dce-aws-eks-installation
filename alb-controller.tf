# AWS Load Balancer Controller Resources
# This file contains the necessary resources to deploy AWS Load Balancer Controller
# as part of the Terraform infrastructure deployment

# Data source for AWS Load Balancer Controller IAM policy (latest version)
data "http" "aws_load_balancer_controller_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json"
}

# IAM policy for AWS Load Balancer Controller with additional required permissions
resource "aws_iam_policy" "aws_load_balancer_controller" {
  name_prefix = "${var.cluster_name}-alb-controller-"
  path        = var.policy_path != "" ? var.policy_path : "/"
  description = "IAM policy for AWS Load Balancer Controller with all required permissions"
  
  # Use the official policy and add any missing permissions
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      jsondecode(data.http.aws_load_balancer_controller_policy.response_body).Statement,
      [
        {
          Effect = "Allow"
          Action = [
            "elasticloadbalancing:DescribeListenerAttributes",
            "elasticloadbalancing:ModifyListenerAttributes"
          ]
          Resource = "*"
        }
      ]
    )
  })

  tags = {
    Name        = "${var.cluster_name}-alb-controller-policy"
    Environment = var.environment
    Owner       = var.owner_tag
  }
}

# IAM role for AWS Load Balancer Controller service account
resource "aws_iam_role" "aws_load_balancer_controller" {
  name_prefix          = "${var.cluster_name}-alb-controller-"
  path                 = var.role_path != "" ? var.role_path : "/"
  permissions_boundary = var.iam_permissions_boundary != "" ? var.iam_permissions_boundary : null

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Condition = {
          StringEquals = {
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = {
    Name        = "${var.cluster_name}-alb-controller-role"
    Environment = var.environment
    Owner       = var.owner_tag
  }
}

# Attach policy to IAM role
resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller" {
  policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
  role       = aws_iam_role.aws_load_balancer_controller.name
}

# Kubernetes service account for AWS Load Balancer Controller
resource "kubernetes_service_account" "aws_load_balancer_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.aws_load_balancer_controller.arn
    }
  }

  depends_on = [
    module.eks,
    time_sleep.wait_for_cluster,
    aws_iam_role.aws_load_balancer_controller
  ]
}

# Deploy AWS Load Balancer Controller via Helm
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = var.alb_controller_chart_version != "" ? var.alb_controller_chart_version : null

  depends_on = [
    time_sleep.wait_for_cluster,
    kubernetes_service_account.aws_load_balancer_controller,
    aws_iam_role_policy_attachment.aws_load_balancer_controller
  ]

  values = [
    yamlencode({
      clusterName = module.eks.cluster_name
      region      = var.aws_region
      vpcId       = module.vpc.vpc_id
      serviceAccount = {
        create = false
        name   = kubernetes_service_account.aws_load_balancer_controller.metadata[0].name
      }
      # Default tags applied to all AWS resources created by the controller
      defaultTags = {
        Owner       = var.owner_tag
        Environment = var.environment
        ManagedBy   = "aws-load-balancer-controller"
      }
    })
  ]
  # Wait for the controller to be ready
  wait          = true
  wait_for_jobs = true
  timeout       = 600
}

# Output the IAM role ARN
output "aws_load_balancer_controller_role_arn" {
  description = "ARN of the AWS Load Balancer Controller IAM role"
  value       = aws_iam_role.aws_load_balancer_controller.arn
  sensitive   = false
}
