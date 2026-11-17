
variable "gitlab_terraform_state_base" {
  description = "Specifies the GitLab Terraform state API URL of the project hosting every state of the repository, without a trailing slash."
  type        = string

  validation {
    condition     = can(regex("^https://[^/]+/.+/projects/[0-9]+/terraform/state$", var.gitlab_terraform_state_base))
    error_message = "gitlab_terraform_state_base must match https://<host>/<api path>/projects/<project ID>/terraform/state."
  }
}

variable "node_config" {
  description = "Hardware resources and IP offsets for Talos control plane nodes matching service catalog allocations."
  type = map(object({
    ip_suffix = number
    vcpu      = number
    ram       = number
  }))
}

variable "talos_config" {
  description = "Talos settings: the Talos release, which MUST match the boot ISO under packer/output/talos-<version>/, the Kubernetes version, and the KubePrism port."
  type = object({
    talos_version      = string
    kubernetes_version = string
    kubeprism_port     = optional(number, 7445)
  })
}

variable "helm_chart_version" {
  description = "Helm chart versions rendered into cluster.inlineManifests."
  type = object({
    cilium = string
  })
}
