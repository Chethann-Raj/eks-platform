#!/usr/bin/env bash
# Releases controller-owned AWS resources that Terraform does not own.
# Must run BEFORE `terraform destroy`. Safe when the cluster is already gone.
set -euo pipefail

CLUSTER="${CLUSTER:-eks-platform-staging}"
REGION="${REGION:-ap-south-1}"
PROFILE="${PROFILE:-pro}"

if ! aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
     --profile "$PROFILE" >/dev/null 2>&1; then
  echo "Cluster $CLUSTER not found - nothing to release."
  exit 0
fi

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" \
  --profile "$PROFILE" >/dev/null

if ! kubectl version --request-timeout=10s >/dev/null 2>&1; then
  echo "API server unreachable - skipping in-cluster cleanup."
  exit 0
fi

echo "Deleting ingresses (releases ALBs and ExternalDNS records)..."
kubectl delete ingress --all -A --timeout=5m || true

echo "Deleting PVCs (releases EBS volumes)..."
kubectl delete pvc --all -A --timeout=5m || true

echo "Waiting 60s for controllers to finish..."
sleep 60
echo "pre-destroy complete."
