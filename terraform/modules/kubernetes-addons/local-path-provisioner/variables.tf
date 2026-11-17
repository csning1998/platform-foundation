
variable "helm_config" {
  description = "Helm release parameters. The chart_repository is the OCI repository which stores the chart, for example oci://ghcr.io/rancher/local-path-provisioner/charts."
  type = object({
    chart_repository = string
    version          = string
    namespace        = optional(string, "local-path-storage")
  })
}

variable "storage_config" {
  description = "StorageClass and node path. On Talos the node_path MUST be the mount path of a user volume, /var/mnt/<name>."
  type = object({
    node_path      = string
    class_name     = optional(string, "local-path")
    default_class  = optional(bool, false)
    reclaim_policy = optional(string, "Delete")
  })

  validation {
    condition     = contains(["Delete", "Retain"], var.storage_config.reclaim_policy)
    error_message = "storage_config.reclaim_policy MUST be Delete or Retain."
  }
}
