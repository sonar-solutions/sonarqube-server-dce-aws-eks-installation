#!/usr/bin/env bash
#
# pre-destroy-cleanup.sh
#
# Removes AWS resources created by the AWS Load Balancer Controller that
# are not tracked in Terraform state. These resources (NLBs, security
# groups, cross-SG rules) block VPC/subnet deletion during terraform destroy.
#
# Run this BEFORE or AFTER a failed terraform destroy, then retry the destroy.
#
# Usage:
#   ./pre-destroy-cleanup.sh
#   terraform destroy -auto-approve

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

TFVARS="terraform.tfvars.json"

if [[ ! -f "$TFVARS" ]]; then
  echo "ERROR: $TFVARS not found. Run this script from the Terraform project root." >&2
  exit 1
fi

AWS_REGION=$(python3 -c "import json; print(json.load(open('$TFVARS'))['aws_region'])")
CLUSTER_NAME=$(python3 -c "import json; print(json.load(open('$TFVARS'))['cluster_name'])")

echo "Region:  $AWS_REGION"
echo "Cluster: $CLUSTER_NAME"

# ---------------------------------------------------------------------------
# Find the VPC
# ---------------------------------------------------------------------------

VPC_ID=$(aws ec2 describe-vpcs --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=*${CLUSTER_NAME}*" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  echo "No VPC found for cluster $CLUSTER_NAME — nothing to clean up."
  exit 0
fi

echo "VPC:     $VPC_ID"

# ---------------------------------------------------------------------------
# Step 1: Delete the sonarqube-nlb Kubernetes service (if cluster is reachable)
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 1: Kubernetes service cleanup ==="

if kubectl cluster-info &>/dev/null; then
  echo "EKS cluster is reachable."
  if kubectl get svc sonarqube-nlb -n default &>/dev/null; then
    echo "Removing finalizer from sonarqube-nlb service..."
    kubectl patch svc sonarqube-nlb -n default \
      -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    echo "Deleting sonarqube-nlb service..."
    kubectl delete svc sonarqube-nlb -n default --timeout=30s 2>/dev/null || true
    echo "Waiting 10s for LB controller to process deletion..."
    sleep 10
  else
    echo "sonarqube-nlb service not found — skipping."
  fi
else
  echo "EKS cluster not reachable — skipping Kubernetes cleanup."
fi

# ---------------------------------------------------------------------------
# Step 2: Delete load balancers in the VPC
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 2: Delete load balancers ==="

LB_ARNS=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
  --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null || true)

if [[ -n "$LB_ARNS" && "$LB_ARNS" != "None" ]]; then
  for arn in $LB_ARNS; do
    echo "Deleting load balancer: $arn"
    aws elbv2 delete-load-balancer --region "$AWS_REGION" --load-balancer-arn "$arn" 2>/dev/null || true
  done

  # Wait for NLB ENIs to release (can take up to 10 minutes)
  echo "Waiting for load balancer ENIs to release..."
  for i in $(seq 1 60); do
    NLB_ENIS=$(aws ec2 describe-network-interfaces --region "$AWS_REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=interface-type,Values=network_load_balancer" \
      --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || true)
    if [[ -z "$NLB_ENIS" || "$NLB_ENIS" == "None" ]]; then
      echo "ENIs released."
      break
    fi
    echo "  Still waiting... ($i/60)"
    sleep 10
  done
else
  echo "No load balancers found in VPC."
fi

# ---------------------------------------------------------------------------
# Step 3: Delete orphaned target groups
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 3: Delete orphaned target groups ==="

TG_ARNS=$(aws elbv2 describe-target-groups --region "$AWS_REGION" \
  --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" --output text 2>/dev/null || true)

if [[ -n "$TG_ARNS" && "$TG_ARNS" != "None" ]]; then
  for tg in $TG_ARNS; do
    echo "Deleting target group: $tg"
    aws elbv2 delete-target-group --region "$AWS_REGION" --target-group-arn "$tg" 2>/dev/null || true
  done
else
  echo "No orphaned target groups found."
fi

# ---------------------------------------------------------------------------
# Step 4: Delete orphaned k8s-* security groups
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 4: Delete orphaned security groups ==="

K8S_SGS=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=k8s-*" \
  --query 'SecurityGroups[*].GroupId' --output text 2>/dev/null || true)

if [[ -n "$K8S_SGS" && "$K8S_SGS" != "None" ]]; then
  # First pass: revoke any cross-SG ingress rules referencing these SGs
  for sg in $K8S_SGS; do
    REFERENCING_SGS=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" \
      --query "SecurityGroups[?IpPermissions[?UserIdGroupPairs[?GroupId=='$sg']]].GroupId" \
      --output text 2>/dev/null || true)

    for ref_sg in $REFERENCING_SGS; do
      [[ "$ref_sg" == "$sg" ]] && continue  # skip self-references
      echo "Revoking rules in $ref_sg that reference $sg..."
      RULES=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
        --group-ids "$ref_sg" \
        --query "SecurityGroups[0].IpPermissions[?UserIdGroupPairs[?GroupId=='$sg']]" \
        --output json 2>/dev/null || true)
      if [[ -n "$RULES" && "$RULES" != "[]" && "$RULES" != "null" ]]; then
        aws ec2 revoke-security-group-ingress --region "$AWS_REGION" \
          --group-id "$ref_sg" --ip-permissions "$RULES" 2>/dev/null || true
      fi
    done
  done

  # Second pass: delete the SGs
  for sg in $K8S_SGS; do
    echo "Deleting security group: $sg"
    aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$sg" 2>/dev/null || echo "  WARNING: Could not delete $sg (may still have dependencies)"
  done
else
  echo "No orphaned k8s-* security groups found."
fi

# ---------------------------------------------------------------------------
# Step 5: Remove sonarqube-nlb service from Terraform state (if present)
# ---------------------------------------------------------------------------

echo ""
echo "=== Step 5: Terraform state cleanup ==="

if terraform state list 2>/dev/null | grep -q 'kubernetes_service.sonarqube_nlb'; then
  echo "Removing kubernetes_service.sonarqube_nlb from Terraform state..."
  terraform state rm kubernetes_service.sonarqube_nlb 2>/dev/null || true
else
  echo "kubernetes_service.sonarqube_nlb not in state — skipping."
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
echo "Cleanup complete. You can now run: terraform destroy -auto-approve"
