locals {
  name = "${var.project}-${var.environment}"
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner = "ebs.csi.aws.com"
  volume_binding_mode = "WaitForFirstConsumer"
  reclaim_policy      = "Delete"

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}

# EKS creates a default "gp2" StorageClass as part of standard cluster
# bootstrap - it is not a resource this or any other Terraform config
# creates, so it can't simply be redefined out from under itself. Two
# default StorageClasses is an error state (a PVC with no storageClassName
# becomes ambiguous), so gp2's default annotation must be patched to
# "false" on the existing object - an annotation patch via
# kubernetes_annotations, not a competing kubernetes_storage_class_v1
# resource. This patch is not optional: applying gp3 above without it
# leaves the cluster with two default StorageClasses until it's done.
resource "kubernetes_annotations" "gp2_not_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"

  metadata {
    name = "gp2"
  }

  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  force = true
}
