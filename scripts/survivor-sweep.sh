#!/usr/bin/env bash
# Post-destroy check: everything below must print nothing.
set -uo pipefail
R="${REGION:-ap-south-1}"; P="${PROFILE:-pro}"
FOUND=0

check() {
  local label="$1"; shift
  local out; out=$("$@" 2>/dev/null)
  if [[ -n "$out" && "$out" != "None" ]]; then
    echo "SURVIVOR [$label]: $out"; FOUND=1
  fi
}

check clusters aws eks list-clusters --region "$R" --profile "$P" \
  --query 'clusters' --output text
check rds aws rds describe-db-instances --region "$R" --profile "$P" \
  --query 'DBInstances[].DBInstanceIdentifier' --output text
check nat aws ec2 describe-nat-gateways --region "$R" --profile "$P" \
  --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId' --output text
check elb aws elbv2 describe-load-balancers --region "$R" --profile "$P" \
  --query 'LoadBalancers[].LoadBalancerName' --output text
check ebs aws ec2 describe-volumes --region "$R" --profile "$P" \
  --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text
check eip aws ec2 describe-addresses --region "$R" --profile "$P" \
  --query 'Addresses[?AssociationId==null].AllocationId' --output text

[[ $FOUND -eq 0 ]] && echo "Clean - no survivors." || exit 1
