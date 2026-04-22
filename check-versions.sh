#!/bin/bash

# Script to check available Helm chart versions for SonarQube and AWS Load Balancer Controller
# This helps you choose specific versions if needed for production stability

set -e

echo "🔍 Checking available Helm chart versions..."

# Add repositories if not already added
echo "📦 Adding Helm repositories..."
helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube --force-update
helm repo add eks https://aws.github.io/eks-charts --force-update
helm repo update

echo ""
echo "🎯 SonarQube Helm Chart Versions (latest 10):"
echo "============================================="
helm search repo sonarqube/sonarqube --versions | head -11

echo ""
echo "🎯 AWS Load Balancer Controller Helm Chart Versions (latest 10):"
echo "================================================================="
helm search repo eks/aws-load-balancer-controller --versions | head -11

echo ""
echo "💡 Usage Examples:"
echo "=================="
echo "# Use latest versions (default):"
echo "terraform apply"
echo ""
echo "# Use specific SonarQube version:"
echo "terraform apply -var='sonarqube_chart_version=10.4.0'"
echo ""
echo "# Use specific ALB Controller version:" 
echo "terraform apply -var='alb_controller_chart_version=1.7.2'"
echo ""
echo "# Use specific versions for both:"
echo "terraform apply -var='sonarqube_chart_version=10.4.0' -var='alb_controller_chart_version=1.7.2'"
echo ""
echo "# Or update the terraform.tfvars.json file manually"

echo ""
echo "🔄 Current Deployment Status:"
echo "============================"
if [ -f terraform.tfstate ]; then
    echo "SonarQube Chart Version: $(terraform output -raw sonarqube_chart_version 2>/dev/null || echo 'Not deployed')"
    echo "ALB Controller Chart Version: $(terraform output -raw alb_controller_chart_version 2>/dev/null || echo 'Not deployed')"
else
    echo "Infrastructure not yet deployed"
fi

echo ""
echo "✅ Done! Use the information above to choose specific versions if needed."
