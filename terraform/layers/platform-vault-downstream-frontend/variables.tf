
variable "gitlab_terraform_state_base" {
  description = "Specifies the GitLab Terraform state API URL of the project hosting every state of this repository, without a trailing slash."
  type        = string

  validation {
    condition     = can(regex("^https://[^/]+/.+/projects/[0-9]+/terraform/state$", var.gitlab_terraform_state_base))
    error_message = "gitlab_terraform_state_base must match https://<host>/<api path>/projects/<project ID>/terraform/state."
  }
}

variable "target_components" {
  description = "Map of role to the service and the component of the SSoT catalog. The layer resolves each pair to the cluster name of the foundation topology."
  type = map(object({
    service   = string
    component = string
  }))
}

variable "primary_role" {
  description = "Primary role key within target_components."
  type        = string
}

variable "service_config" {
  description = "Compute topology per role of the Downstream Vault. The VM runtime builds one VM per node, and the Talos runtime reads the identity and the network of the role."
  type = map(object({
    role            = string
    network_tier    = optional(string, "default")
    base_image_path = string
    nodes = map(object({
      ip_suffix            = number
      vcpu                 = number
      ram_size             = number
      os_disk_capacity_gib = optional(number)
    }))
  }))
}

variable "pki_identity" {
  description = "Identity of the intermediate CA which the Downstream Vault holds: the common name of the CA and the mount path of the PKI engine."
  type = object({
    intermediate_ca_common_name = string
    intermediate_mount_path     = string
  })

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]+$", var.pki_identity.intermediate_mount_path))
    error_message = "The intermediate_mount_path value MUST contain only alphanumeric characters, underscores, and hyphens for Vault policy path interpolation."
  }
}

variable "node_config" {
  description = "Hardware resources and IP offsets for Talos control plane nodes. Required on the Talos runtime."
  type = map(object({
    ip_suffix = number
    vcpu      = number
    ram       = number
  }))
  default = {}
}

variable "volume_config" {
  description = "Talos user volume which formats the raft data disk at device and mounts the disk at /var/mnt/<name>."
  type = object({
    name   = string
    device = optional(string, "/dev/vdb")
  })
  default = {
    name = "vault-raft"
  }
}

variable "talos_config" {
  description = "Talos settings: the Talos release, which MUST match the boot ISO under packer/output/talos-<version>/, the Kubernetes version, and the KubePrism port. Required on the Talos runtime."
  type = object({
    talos_version      = string
    kubernetes_version = string
    kubeprism_port     = optional(number, 7445)
  })
  default = null
}

variable "helm_chart_version" {
  description = "Helm chart versions rendered into cluster.inlineManifests. Required on the Talos runtime."
  type = object({
    cilium       = string
    cert_manager = string
  })
  default = null
}
