# terraform/modules/eks

Reusable EKS module: cluster, managed nodegroup, OIDC/IRSA, core addons and
variable-driven Access Entries. Per `CLAUDE.md` §4, §5, §8.

## Why this can't `plan` standalone

Same reasoning as `terraform/modules/vpc/`: no `backend` block, no
`provider "aws" {}` block, only `required_providers`. It's a child module -
plannable only once `terraform/envs/staging/` composes it with the vpc
module's outputs as inputs. Provider pins (`aws ~> 6.62.0`, `tls ~> 4.0.6`,
matching persistent/) still constrain what the root resolves to.

## Node security group ID

Output as `node_security_group_id`, needed by the RDS module for its 5432
ingress rule. This module doesn't create a dedicated node security group -
`aws_eks_node_group.default` has no `launch_template` block, so EKS attaches
its own auto-created "cluster security group" to every node (the same one
attached to the control plane ENIs). That computed ID -
`aws_eks_cluster.this.vpc_config[0].cluster_security_group_id` - is exactly
what governs node network traffic today, so it's what gets output rather
than standing up a redundant second SG.

## `desired_size` and Terraform drift

Nothing autoscales the nodegroup yet, but `aws_eks_node_group.default` in
`node_group.tf` already carries:

```hcl
lifecycle {
  ignore_changes = [scaling_config[0].desired_size]
}
```

Two things can move `desired_size` outside of this Terraform config once
they exist:

1. A **Cluster Autoscaler** - not deployed by this module, but Phase 2's HPA
   (min 2 / max 6 pods, target 70% CPU) will eventually push pod count past
   what 3 nodes can schedule, which needs something to scale *nodes*, not
   just pods. Whatever does that edits the nodegroup's live desired count
   directly.
2. **Spot interruption replacement** - AWS can cycle a node without going
   through this Terraform config at all.

Without `ignore_changes`, every `terraform plan` after either would show a
diff trying to reset `desired_size` back to `var.node_desired_size`, and an
`apply` would actively undo whatever the autoscaler or AWS just did.
`min_size`/`max_size` are **not** in `ignore_changes` - those are capacity
bounds this config should always own, not a live scaling decision. To change
the starting size on purpose, edit `node_desired_size` and apply normally.

## Addon ordering and `bootstrap_self_managed_addons = false`

`aws_eks_cluster.this` sets `bootstrap_self_managed_addons = false`, so EKS
does not auto-install its own default vpc-cni/coredns/kube-proxy at cluster
creation. That leaves the four `aws_eks_addon` resources in `addons.tf` as
the *only* source of these components and their versions - nothing
pre-existing to conflict with (hence `resolve_conflicts_on_*  = "OVERWRITE"`
being safe rather than papering over a real conflict).

Explicit `depends_on` chain, since order matters:

1. `vpc_cni`, `kube_proxy` - right after the cluster. Neither needs nodes to
   exist; both need to be registered *before* nodes join, since with
   self-managed addons off there is otherwise no pod networking or service
   routing at all for a newly-joined node.
2. `aws_eks_node_group.default` - depends on both of the above.
3. `coredns` - depends on the node group. Its pods need somewhere to
   schedule; creating it before any node exists risks the addon getting
   stuck `DEGRADED` instead of reaching `ACTIVE`.
4. `aws-ebs-csi-driver` - depends on the node group and its own IRSA role's
   policy attachment. Uses a dedicated `ebs-csi-controller-sa` IRSA role
   (`aws_iam_role.ebs_csi`), not the node role - the node role only carries
   `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy` and
   `AmazonEC2ContainerRegistryReadOnly`, nothing S3/EBS-specific.

Addon versions (`vpc_cni_version`, `coredns_version`, `kube_proxy_version`,
`ebs_csi_version`) are pinned explicitly rather than left to default to
whatever EKS currently recommends - see the comment in `variables.tf` for
how the current defaults were sourced and how to refresh them.

## Access Entries are entirely variable-driven

`var.access_entries` is the only way a principal gets cluster access
(`authentication_mode = "API"`, no `aws-auth` ConfigMap). This module has no
hardcoded ARNs. `envs/staging` is expected to pass both the terraform-admin
user (`AmazonEKSClusterAdminPolicy`, cluster-scoped) and the persistent
layer's `ci_deploy_role_arn` (`AmazonEKSEditPolicy`, scoped to the `staging`
namespace) - see the example in `variables.tf`.

`bootstrap_cluster_creator_admin_permissions = false` on purpose: admin
access should come from an explicit, declared access entry, not from an
implicit "whoever ran apply is admin" grant that Terraform doesn't manage.
