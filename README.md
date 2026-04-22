# SonarQube Server Enterprise Edition - EKS Deployment

This directory contains Terraform templates for deploying SonarQube Server Enterprise Edition on Amazon Elastic Kubernetes Service (ESK).

## ✅ Status: Fully Implemented and Tested

This deployment method is production-ready and includes all necessary components for a complete SonarQube installation.

## 🏗️ Infrastructure Components

- **EKS Cluster**: Managed Kubernetes cluster with configurable node groups
- **VPC & Networking**: Custom VPC with public/private subnets across multiple AZs
- **RDS Database**: Managed PostgreSQL database for SonarQube data persistence
- **Application Load Balancer**: AWS ALB with SSL/TLS termination
- **Route53 DNS**: Domain name management and DNS routing
- **ACM Certificate**: Automated SSL certificate provisioning

## 🚀 Key Features

- **Helm-based Deployment**: Uses official SonarQube Helm charts
- **Version Management**: Configurable chart versions for production stability
- **Security**: IAM roles, security groups, and network policies
- **Scalability**: Auto-scaling node groups and horizontal pod scaling

## 📋 Prerequisites

- **Terraform**: Essential for deploying the template
- **AWS CLI**
- **kubectl**: For Kubernetes cluster management
- **Helm**: Needed to deploy/diagnose charts
- **Domain**: Registered domain and a zone file for SSL certificate and routing

## 🛠️ Quick Start

1. **Configure variables**
   ```bash
   cp terraform.tfvars.json.example terraform.tfvars.json
   # Edit terraform.tfvars.json with your specific values
   ```
   Alternatively, you can use the supplied update_variables.py script:
   ```bash
   python3 ./update_variables.py
   ```

2. **Check available Helm chart versions** (optional)
   ```bash
   ./check-versions.sh
   ```

3. **Deploy infrastructure**
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

4. **Access SonarQube**
   - URL: `https://sonarqube.your-domain.com`
   - Default credentials: `admin/admin` (change immediately)

5. **Access the EKS Cluster** (for kubectl management)
   
   The cluster uses an IAM role for administration access. To interact with the cluster using kubectl:
   
   ```bash
   # Get the role ARN from Terraform outputs
   export ROLE_ARN=$(terraform output -raw eks_admin_role_arn)
   
   # Assume the role (replace with your session name)
   aws sts assume-role \
     --role-arn $ROLE_ARN \
     --role-session-name eks-admin-session \
     --external-id "$(terraform output -raw cluster_name)-eks-admin"
   
   # Configure AWS credentials with the temporary credentials from assume-role output
   export AWS_ACCESS_KEY_ID=<AccessKeyId from output>
   export AWS_SECRET_ACCESS_KEY=<SecretAccessKey from output>
   export AWS_SESSION_TOKEN=<SessionToken from output>
   
   # Update kubeconfig
   aws eks update-kubeconfig --name $(terraform output -raw cluster_name) --region $(terraform output -raw aws_region)
   
   # Verify access
   kubectl get nodes
   ```
   
   **Note**: Your IAM user/role must have permission to assume the EKS admin role in your AWS account.

## ⚙️ Configuration

### Required Variables
```json
{
  "aws_region": "eu-central-1",
  "cluster_name": "my-eks-cluster", 
  "kubernetes_version": "1.33",
  "environment": "Production",
  "vpc_cidr": "10.0.0.0/16",
  "private_subnets": ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"],
  "public_subnets": ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"],
  "availability_zones": ["eu-central-1a", "eu-central-1b", "eu-central-1c"],
  "owner_tag": "Your Name",
  "node_instance_types": ["t3.large"],
  "eks_admin_role_name": "eks-cluster-admin",
  "role_path": "/",
  "policy_path": "/",
  "iam_permissions_boundary": "",
  "domain_name": "your-domain.com",
  "db_name": "sonarqube",
  "db_username": "sonarqube"
}
```

### Optional Variables
- `sonarqube_chart_version`: Specific SonarQube Helm chart version (default: latest)
- `alb_controller_chart_version`: Specific ALB Controller chart version (default: latest)
- `eks_admin_role_name`: Name of the IAM role for EKS cluster administration (default: "eks-cluster-admin")
- `role_path`: IAM path for IAM roles created by this configuration (default: "/")
  - Applied to: EKS admin role and ALB controller role
  - Must start and end with `/` (e.g., `/approles/`, `/service-roles/`, or `/`)
  - Required if your AWS organization has SCPs restricting IAM role creation paths
- `policy_path`: IAM path for IAM policies created by this configuration (default: "/")
  - Applied to: ALB controller policy
  - Must start and end with `/` (e.g., `/apppolicies/`, `/service-policies/`, or `/`)
  - Required if your AWS organization has SCPs mandating specific policy paths
- `iam_permissions_boundary`: ARN of the IAM permissions boundary policy to attach to all IAM roles (default: "")
  - Example: `"arn:aws:iam::123456789012:policy/AppPermissionsBoundary-V1"`
  - Required if your AWS organization has SCPs mandating permissions boundaries
  - Leave empty if not required by your organization

## 🔧 Utilities

### Version Checker Script
The `check-versions.sh` script helps you:
- View available Helm chart versions
- Check current deployment status
- Get usage examples for version pinning

```bash
./check-versions.sh
```

### Variable Update Script
The `update_variables.py` script assists with configuration management and variable updates.

## 📁 Terraform Configuration Files

This project is organized into modular Terraform files, each handling specific infrastructure components:

### `main.tf`
The primary configuration file containing:
- Terraform and provider configurations (AWS, Kubernetes, Helm, HTTP, Time)
- VPC module setup with public/private subnets, NAT gateways, and DNS settings
- EKS cluster configuration with managed node groups and cluster addons (CoreDNS, kube-proxy, VPC-CNI)
- Kubernetes secrets and ConfigMaps for database credentials and JDBC configuration
- Random password generation for database and monitoring
- SonarQube Helm chart deployment with dynamic ingress configuration
- Multiple outputs for cluster information, URLs, and connection details

### `variables.tf`
Defines all input variables used across the infrastructure:
- AWS region, cluster name, and Kubernetes version
- Network configuration (VPC CIDR, subnets, availability zones)
- Instance types and node group settings
- Domain and host names for DNS configuration
- Database credentials (name and username)
- Optional Helm chart version pinning
- Owner tags and user ARN for access control

### `rds.tf`
PostgreSQL database infrastructure:
- RDS subnet group for database placement in private subnets
- Security group restricting database access to EKS nodes only
- RDS PostgreSQL instance with encryption, automated backups, and auto-scaling storage
- Configuration for maintenance windows and backup retention

### `alb-controller.tf`
AWS Load Balancer Controller deployment:
- IAM policy and role with OIDC federation for service account
- Kubernetes service account with IAM role annotation
- Helm deployment of AWS Load Balancer Controller
- Required permissions for managing AWS Application Load Balancers

### `acm.tf`
SSL/TLS certificate management:
- AWS Certificate Manager (ACM) certificate request for the SonarQube domain
- DNS validation method configuration
- Lifecycle management to prevent resource recreation issues

### `route53.tf`
DNS and certificate validation:
- Route53 hosted zone lookup for existing domain
- A record (alias) pointing to the ALB created by the ingress
- ACM certificate validation records
- Certificate validation resource to wait for DNS propagation

## 🏢 AWS Resources Created

- EKS Cluster with managed node groups
- VPC with public/private subnets
- Internet Gateway and NAT Gateways
- Route tables and security groups
- RDS PostgreSQL instance
- EFS file system and mount targets
- Application Load Balancer
- Route53 hosted zone and records
- ACM SSL certificate
- IAM roles and policies
- CloudWatch log groups

## 🔒 Security Features

- All traffic encrypted in transit (HTTPS/TLS)
- Database credentials managed via AWS Secrets Manager
- IAM roles follow least privilege principle
- Security groups restrict access to necessary ports only
- Private subnets for worker nodes and database
- Network ACLs for additional security layers
