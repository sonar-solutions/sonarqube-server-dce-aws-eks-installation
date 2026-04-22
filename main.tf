# main.tf
terraform {
  required_version = ">= 1.5.7"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = ">= 6.0.0, < 7.0.0"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "~> 2.20"
    }
    random = {
      source = "hashicorp/random"
      version = "~> 3.1"
    }
    helm = {
      source = "hashicorp/helm"
      version = "~> 2.12"
    }
    http = {
      source = "hashicorp/http"
      version = "~> 3.4"
    }
    time = {
      source = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
provider "aws" {
  region = var.aws_region
}

# Kubernetes provider configuration using exec-based authentication
# This generates fresh tokens on each request, which is more robust for both
# create and destroy operations compared to static token authentication
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

# Helm provider configuration using exec-based authentication
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}

# IAM Role for EKS Cluster Administration
# This role can be assumed by AWS users/roles to manage the EKS cluster
data "aws_caller_identity" "current" {}

# IAM Role for EKS Cluster
# Explicitly created to apply permissions boundary and path required by SCP
resource "aws_iam_role" "eks_cluster" {
  name                 = "${var.cluster_name}-cluster"
  path                 = var.role_path != "" ? var.role_path : "/"
  permissions_boundary = var.iam_permissions_boundary != "" ? var.iam_permissions_boundary : null

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "${var.cluster_name}-cluster-role"
    Environment = var.environment
    Owner       = var.owner_tag
  }
}

# Attach required EKS cluster policies
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.eks_cluster.name
}

# IAM Role for EKS Node Group
# Explicitly created to apply permissions boundary and path required by SCP
resource "aws_iam_role" "eks_node_group" {
  name                 = "${var.cluster_name}-node-group"
  path                 = var.role_path != "" ? var.role_path : "/"
  permissions_boundary = var.iam_permissions_boundary != "" ? var.iam_permissions_boundary : null

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "${var.cluster_name}-node-group-role"
    Environment = var.environment
    Owner       = var.owner_tag
  }
}

# Attach required node group policies
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_group.name
}

resource "aws_iam_role_policy_attachment" "eks_container_registry_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_group.name
}



# IAM Role for EKS Admin (user access to cluster)
resource "aws_iam_role" "eks_admin" {
  name                 = "${var.cluster_name}-${var.eks_admin_role_name}"
  path                 = var.role_path != "" ? var.role_path : "/"
  permissions_boundary = var.iam_permissions_boundary != "" ? var.iam_permissions_boundary : null
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = "${var.cluster_name}-eks-admin"
          }
        }
      }
    ]
  })
  
  tags = {
    Name        = "${var.cluster_name}-${var.eks_admin_role_name}"
    Environment = var.environment
    Owner       = var.owner_tag
    Purpose     = "EKS Cluster Administration"
  }
}

# Policy to allow the role to access EKS cluster
resource "aws_iam_role_policy" "eks_admin_policy" {
  name = "eks-cluster-access"
  role = aws_iam_role.eks_admin.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:AccessKubernetesApi"
        ]
        Resource = "*"
      }
    ]
  })
}

# VPC Configuration
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr
  azs = var.availability_zones
  private_subnets = var.private_subnets
  public_subnets = var.public_subnets
  enable_nat_gateway = true
  enable_vpn_gateway = false
  enable_dns_hostnames = true
  enable_dns_support = true

  tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    Environment = var.environment
    Owner = var.owner_tag
  }
  public_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb" = "1"
    Owner = var.owner_tag
  }
  private_subnet_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb" = "1"
    Owner = var.owner_tag
  }

}

# EKS Configuration
module "eks" {
  source = "terraform-aws-modules/eks/aws"
  version = "~> 21.1.5"

  name = var.cluster_name
  kubernetes_version = var.kubernetes_version
  
  timeouts = {
    create = "50m"
    delete = "15m"
    update = "50m"
  }

  vpc_id = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_private_access = true
  endpoint_public_access = true
  
  # Use explicitly created IAM role to comply with potentially restrictive SCP requirements
  create_iam_role = false
  iam_role_arn    = aws_iam_role.eks_cluster.arn
  
  # Addons needed for the cluster to work
  # Note: CoreDNS needs nodes to run on, so it should NOT have before_compute = true
  addons = {
    vpc-cni = {
      most_recent = true
      before_compute = true  # VPC CNI is needed for pod networking
      resolve_conflicts_on_update = "OVERWRITE"
    }
    kube-proxy = {
      most_recent = true
      before_compute = true  # Kube-proxy can run before nodes
      resolve_conflicts_on_update = "OVERWRITE"
    }
    coredns = {
      most_recent = true
      # IMPORTANT: Do NOT set before_compute = true for CoreDNS
      # CoreDNS pods need nodes to run on, so it must wait for node groups to be created
      before_compute = true
      resolve_conflicts_on_update = "OVERWRITE"
    }
    #depends_on = [module.vpc]
  }
  
  # Add node groups
  eks_managed_node_groups = {
    sonarqube = {
      name = "sonarqube-nodes"
      instance_types = var.node_instance_types
      capacity_type = "ON_DEMAND"
      min_size = 1
      max_size = 3
      # DCE requires: 2 app nodes + 3 search nodes = 5 SonarQube pods.
      desired_size = 3
      disk_size = 50

      # Restrict to a single AZ for low-latency inter-pod communication.
      # All five SonarQube pods (app + search) will land on nodes in
      # availability_zones[0] (eu-central-1a by default).
      subnet_ids = [module.vpc.private_subnets[0]]

      # Use explicitly created IAM role to comply with SCP requirements
      create_iam_role = false
      iam_role_arn    = aws_iam_role.eks_node_group.arn

      # IMPORTANT: When using a custom IAM role, we need to explicitly configure
      # the role to be allowed in the cluster via access entries (not aws-auth)
      # This is handled by the EKS module when create_iam_role = false

      labels = {
        Environment = var.environment
        Application = "sonarqube"
      }

      tags = {
        Environment = var.environment
        Owner       = var.owner_tag
      }
    }
  }
  
  # Enable access entry API for node group authentication
  # This is the modern way to grant access instead of aws-auth ConfigMap
  enable_cluster_creator_admin_permissions = true

  # Access needed for kubectl to work
  # Using IAM role for EKS cluster administration
  access_entries = {
    admin = {
      principal_arn = aws_iam_role.eks_admin.arn
      type = "STANDARD"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  tags = {
    Environment = var.environment
    Owner = var.owner_tag
  }
}

# Generate random password for SonarQube database
resource "random_password" "sonarqube_db_password" {
  length  = 16
  special = true
  upper   = true
  lower   = true
  numeric = true
  # Exclude characters that AWS RDS doesn't allow: /, @, ", and space
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Wait for EKS cluster to be fully ready before creating Kubernetes resources
# This ensures the cluster API is accessible and ready to accept requests
resource "time_sleep" "wait_for_cluster" {
  depends_on = [module.eks]

  create_duration = "60s"

  triggers = {
    cluster_endpoint = module.eks.cluster_endpoint
    cluster_name     = module.eks.cluster_name
  }
}

# Create Kubernetes secret for SonarQube database password
resource "kubernetes_secret" "sonarqube_db_password" {
  metadata {
    name      = "sonarqube-eks-db-password"
    namespace = "default"
  }
  data = {
    password = random_password.sonarqube_db_password.result
  }

  type = "Opaque"

  depends_on = [
    time_sleep.wait_for_cluster
  ]
}

# Create Kubernetes secret for SonarQube monitoring password
resource "random_password" "sonarqube_monitoring_password" {
  length  = 16
  special = true
  upper   = true
  lower   = true
  numeric = true
  # Exclude characters that AWS RDS doesn't allow: /, @, ", and space
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "kubernetes_secret" "sonarqube_monitoring_password" {
  metadata {
    name      = "sonarqube-eks-monitoring-password"
    namespace = "default"
  }
  data = {
    password = random_password.sonarqube_monitoring_password.result
  }

  type = "Opaque"

  depends_on = [
    time_sleep.wait_for_cluster
  ]
}

# JWT secret used by DCE application nodes to authenticate with each other.
# Must be a base64-encoded string of at least 32 characters.
resource "random_password" "sonarqube_jwt_secret" {
  length  = 32
  special = false
  upper   = true
  lower   = true
  numeric = true
}

# Create Kubernetes ConfigMap for SonarQube JDBC configuration
resource "kubernetes_config_map" "sonarqube_opts" {
  metadata {
    name      = "sonarqube-opts"
    namespace = "default"
  }
  
  data = {
    SONAR_JDBC_USERNAME = var.db_username
    SONAR_JDBC_URL      = "jdbc:postgresql://${aws_db_instance.sonarqube.endpoint}/${aws_db_instance.sonarqube.db_name}"
  }

  depends_on = [
    time_sleep.wait_for_cluster,
    aws_db_instance.sonarqube
  ]
}

# Terraform outputs for RDS connection information
output "jdbc_url" {
  description = "JDBC connection URL for the RDS instance"
  value       = "jdbc:postgresql://${aws_db_instance.sonarqube.endpoint}/${aws_db_instance.sonarqube.db_name}"
  sensitive   = false
}

# Terraform outputs
output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = var.cluster_name
  sensitive   = false
}

output "eks_admin_role_arn" {
  description = "ARN of the IAM role for EKS cluster administration"
  value       = aws_iam_role.eks_admin.arn
  sensitive   = false
}

output "eks_admin_role_name" {
  description = "Name of the IAM role for EKS cluster administration"
  value       = aws_iam_role.eks_admin.name
  sensitive   = false
}

output "eks_cluster_role_arn" {
  description = "ARN of the EKS cluster IAM role"
  value       = aws_iam_role.eks_cluster.arn
  sensitive   = false
}

output "eks_node_group_role_arn" {
  description = "ARN of the EKS node group IAM role"
  value       = aws_iam_role.eks_node_group.arn
  sensitive   = false
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
  sensitive   = false
}

output "domain_name" {
  description = "Base domain name"
  value       = var.domain_name
  sensitive   = false
}

output "acm_arn" {
  description = "ARN of the ACM certificate for SonarQube"
  value       = aws_acm_certificate_validation.sonarqube.certificate_arn
  sensitive   = false
}

output "route53_zone_id" {
  description = "Route53 hosted zone ID"
  value       = data.aws_route53_zone.existing.zone_id
  sensitive   = false
}

# Deploy SonarQube Data Center Edition via Helm.
# Dynamic values (ingress, AZ affinity, JWT secret) are merged on top of
# the static sonarqube-values.yaml via yamlencode blocks — later values
# take precedence in Helm's merge order.
resource "helm_release" "sonarqube" {
  name       = "sonarqube"
  repository = "https://SonarSource.github.io/helm-chart-sonarqube"
  chart      = "sonarqube-dce"
  namespace  = "default"
  version    = var.sonarqube_chart_version != "" ? var.sonarqube_chart_version : null

  values = [
    # Base DCE values from the static file
    file("${path.module}/sonarqube-values.yaml"),

    # JWT secret for stateless DCE app-node clustering (base64-encoded)
    # Also provides JDBC URL and username required by the DCE chart validation
    yamlencode({
      ApplicationNodes = {
        jwtSecret = base64encode(random_password.sonarqube_jwt_secret.result)
      }
      jdbcOverwrite = {
        enabled                = true
        jdbcUrl                = "jdbc:postgresql://${aws_db_instance.sonarqube.endpoint}/${aws_db_instance.sonarqube.db_name}"
        jdbcUsername           = var.db_username
        jdbcSecretName         = "sonarqube-eks-db-password"
        jdbcSecretPasswordKey  = "password"
      }
    }),

    # Node affinity: pin all pods to the first AZ so inter-pod latency is minimal.
    # Both ApplicationNodes and searchNodes get the same constraint.
    yamlencode({
      ApplicationNodes = {
        affinity = {
          nodeAffinity = {
            requiredDuringSchedulingIgnoredDuringExecution = {
              nodeSelectorTerms = [
                {
                  matchExpressions = [
                    {
                      key      = "topology.kubernetes.io/zone"
                      operator = "In"
                      values   = [var.availability_zones[0]]
                    }
                  ]
                }
              ]
            }
          }
        }
      }
      searchNodes = {
        affinity = {
          nodeAffinity = {
            requiredDuringSchedulingIgnoredDuringExecution = {
              nodeSelectorTerms = [
                {
                  matchExpressions = [
                    {
                      key      = "topology.kubernetes.io/zone"
                      operator = "In"
                      values   = [var.availability_zones[0]]
                    }
                  ]
                }
              ]
            }
          }
        }
      }
    }),

    # NLB Service configuration — port 443 with TLS termination → pod port 9000
    # NLBs operate at Layer 4 and are provisioned via Service annotations (not Ingress).
    yamlencode({
      ingress = {
        enabled = false
      }
      service = {
        type         = "LoadBalancer"
        externalPort = 443
        internalPort = 9000
        annotations = {
          # Tell the AWS Load Balancer Controller to provision an NLB
          "service.beta.kubernetes.io/aws-load-balancer-type"                            = "external"
          "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type"                 = "ip"
          "service.beta.kubernetes.io/aws-load-balancer-scheme"                          = "internet-facing"
          # TLS termination at the NLB; plain TCP forwarded to pods on port 9000
          "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"                        = aws_acm_certificate.sonarqube.arn
          "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"                       = "443"
          "service.beta.kubernetes.io/aws-load-balancer-backend-protocol"                = "tcp"
          # HTTP health check against the SonarQube status endpoint
          "service.beta.kubernetes.io/aws-load-balancer-healthcheck-path"                = "/api/system/status"
          "service.beta.kubernetes.io/aws-load-balancer-healthcheck-protocol"            = "HTTP"
          "service.beta.kubernetes.io/aws-load-balancer-healthcheck-healthy-threshold"   = "2"
          "service.beta.kubernetes.io/aws-load-balancer-healthcheck-unhealthy-threshold" = "2"
        }
      }
    })
  ]

  depends_on = [
    time_sleep.wait_for_cluster,
    helm_release.aws_load_balancer_controller,
    aws_acm_certificate_validation.sonarqube,
    kubernetes_secret.sonarqube_db_password,
    kubernetes_secret.sonarqube_monitoring_password,
    kubernetes_config_map.sonarqube_opts
  ]

  # Wait for SonarQube to be ready
  wait          = true
  wait_for_jobs = true
  timeout       = 900
}

output "sonarqube_url" {
  description = "Complete HTTPS URL for SonarQube"
  value       = "https://${var.host_name}.${var.domain_name}"
  sensitive   = false
}

output "load_balancer_dns" {
  description = "DNS name of the AWS Load Balancer"
  value       = data.aws_lb.sonarqube_nlb.dns_name
  sensitive   = false
}

output "load_balancer_zone_id" {
  description = "Zone ID of the AWS Load Balancer"
  value       = data.aws_lb.sonarqube_nlb.zone_id
  sensitive   = false
}

output "sonarqube_chart_version" {
  description = "Version of SonarQube Helm chart deployed (or 'latest' if using latest)"
  value       = var.sonarqube_chart_version != "" ? var.sonarqube_chart_version : "latest"
  sensitive   = false
}

output "alb_controller_chart_version" {
  description = "Version of AWS Load Balancer Controller Helm chart deployed (or 'latest' if using latest)"
  value       = var.alb_controller_chart_version != "" ? var.alb_controller_chart_version : "latest"
  sensitive   = false
}

output "sonarqube_jdbc_url" {
  description = "JDBC URL used by SonarQube to connect to the database"
  value       = "jdbc:postgresql://${aws_db_instance.sonarqube.endpoint}/${aws_db_instance.sonarqube.db_name}"
  sensitive   = false
}

output "sonarqube_jdbc_username" {
  description = "JDBC username used by SonarQube"
  value       = var.db_username
  sensitive   = false
}

