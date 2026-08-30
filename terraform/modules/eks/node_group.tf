data "aws_iam_policy_document" "node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${local.name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_readonly" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# No custom launch_template block, so this node group uses EKS's
# auto-created "cluster security group" for its nodes - the same SG
# attached to the control plane ENIs (aws_eks_cluster.this.vpc_config[0].
# cluster_security_group_id, exposed below as node_security_group_id).
# That's the SG the RDS module's 5432 ingress rule needs to reference.
resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.name}-default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  capacity_type  = var.node_capacity_type
  instance_types = var.node_instance_types
  ami_type       = var.node_ami_type

  scaling_config {
    min_size     = var.node_min_size
    desired_size = var.node_desired_size
    max_size     = var.node_max_size
  }

  # vpc-cni and kube-proxy must be registered before nodes join: with
  # bootstrap_self_managed_addons = false (main.tf) EKS installs no default
  # networking/proxy DaemonSets of its own, so without this order nodes
  # would join with no pod networking and no service routing at all.
  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_readonly,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
  ]

  # desired_size drift: nothing autoscales the nodegroup today, but this is
  # here ahead of that. Two separate things can change desired_size outside
  # of this Terraform config once something does:
  #   1. A future Cluster Autoscaler (needed once Phase 2's HPA scales pod
  #      count past what 3 nodes can schedule) edits the underlying ASG's
  #      desired count directly via the EKS API, not through this file.
  #   2. AWS itself can replace an interrupted Spot instance and the
  #      resulting count can be observed as "drift" against the value
  #      recorded here, even with no capacity change intended.
  # Without ignore_changes, every `terraform plan` after either of those
  # would show a diff wanting to reset desired_size back to var.node_
  # desired_size - and an `apply` would actively fight the autoscaler by
  # scaling live capacity back down. min_size and max_size stay fully
  # Terraform-managed (those are capacity *bounds*, not a live scaling
  # decision); only desired_size is excluded. To change the starting size
  # deliberately, edit node_desired_size and apply as normal - Terraform
  # will pick it up the next time this resource is otherwise modified.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  # Default create timeout is 60m. An ASG launch failure such as an invalid
  # instance type, insufficient Spot capacity, or an account-plan restriction
  # is normally knowable within a few minutes, but the EKS nodegroup waiter
  # can continue much longer. The first Free Tier failure took ~33 minutes
  # to surface. 10m is intentionally long enough for a healthy staging
  # nodegroup create while keeping failed attempts from consuming the full
  # default timeout.
  timeouts {
    create = "10m"
    update = "20m"
    delete = "20m"
  }
}
