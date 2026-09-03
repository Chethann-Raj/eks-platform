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
check rds-manual-snapshots aws rds describe-db-snapshots --region "$R" --profile "$P" \
  --snapshot-type manual --query 'DBSnapshots[].DBSnapshotIdentifier' --output text
check rds-automated-snapshots aws rds describe-db-snapshots --region "$R" --profile "$P" \
  --snapshot-type automated --query 'DBSnapshots[].DBSnapshotIdentifier' --output text
check nat aws ec2 describe-nat-gateways --region "$R" --profile "$P" \
  --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId' --output text
check elb aws elbv2 describe-load-balancers --region "$R" --profile "$P" \
  --query 'LoadBalancers[].LoadBalancerName' --output text
check target-groups aws elbv2 describe-target-groups --region "$R" --profile "$P" \
  --query 'TargetGroups[].TargetGroupName' --output text
check ebs aws ec2 describe-volumes --region "$R" --profile "$P" \
  --filters Name=status,Values=available --query 'Volumes[].VolumeId' --output text
check eip aws ec2 describe-addresses --region "$R" --profile "$P" \
  --query 'Addresses[?AssociationId==null].AllocationId' --output text
check enis aws ec2 describe-network-interfaces --region "$R" --profile "$P" \
  --filters Name=status,Values=available --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
check security-groups aws ec2 describe-security-groups --region "$R" --profile "$P" \
  --filters Name=tag:Name,Values="eks-platform-staging*" \
  --query 'SecurityGroups[].GroupId' --output text
check eks-log-groups aws logs describe-log-groups --region "$R" --profile "$P" \
  --log-group-name-prefix "/aws/eks/eks-platform-staging" --query 'logGroups[].logGroupName' --output text
check vpc-flow-log-groups aws logs describe-log-groups --region "$R" --profile "$P" \
  --log-group-name-prefix "/aws/vpc-flow-log/eks-platform-staging" --query 'logGroups[].logGroupName' --output text
check iam-roles aws iam list-roles --profile "$P" \
  --query "Roles[?starts_with(RoleName, 'eks-platform-staging')].RoleName" --output text

[[ $FOUND -eq 0 ]] && echo "Clean - no survivors." || exit 1
