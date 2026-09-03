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

echo "Waiting for the staging ALB to actually disappear (up to 5m)..."
gone=0
for i in $(seq 1 30); do
  remaining=$(aws elbv2 describe-load-balancers --region "$REGION" --profile "$PROFILE" \
    --query "LoadBalancers[?starts_with(LoadBalancerName, 'k8s-staging-')].LoadBalancerArn" \
    --output text 2>/dev/null || true)
  if [ -z "$remaining" ] || [ "$remaining" = "None" ]; then
    echo "Staging ALB gone."
    gone=1
    break
  fi
  echo "  still present (attempt $i/30): $remaining"
  sleep 10
done

if [ "$gone" -ne 1 ]; then
  echo "ERROR: staging ALB still present after 5m - refusing to continue into terraform destroy." >&2
  exit 1
fi

echo "Deleting ExternalSecret and ClusterSecretStore custom resources..."
kubectl delete externalsecret --all -A --timeout=2m 2>/dev/null || true
kubectl delete clustersecretstore --all --timeout=2m 2>/dev/null || true

echo "Uninstalling external-secrets while the cluster still has egress and a healthy webhook..."
if helm status external-secrets -n external-secrets >/dev/null 2>&1; then
  helm uninstall external-secrets -n external-secrets --wait --timeout 2m || true
fi

echo "Deleting the staging namespace..."
if kubectl get namespace staging >/dev/null 2>&1; then
  if ! kubectl delete namespace staging --wait --timeout=2m; then
    echo "ERROR: staging namespace did not terminate within 2m - refusing to continue into terraform destroy." >&2
    exit 1
  fi
fi

echo "Deleting PVCs (releases EBS volumes)..."
kubectl delete pvc --all -A --timeout=5m || true

echo "pre-destroy complete."
