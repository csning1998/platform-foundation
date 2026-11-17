
variable "gitlab_terraform_state_base" {
  description = "Specifies the GitLab Terraform state API URL of the project hosting every state of this repository, without a trailing slash."
  type        = string

  validation {
    condition     = can(regex("^https://[^/]+/.+/projects/[0-9]+/terraform/state$", var.gitlab_terraform_state_base))
    error_message = "gitlab_terraform_state_base must match https://<host>/<api path>/projects/<project ID>/terraform/state."
  }
}

variable "node_config" {
  description = "Configuration for Talos load balancer nodes (resources and IP suffix)."
  type = map(object({
    ip_suffix = number
    vcpu      = number
    ram       = number
  }))
}

variable "talos_config" {
  description = "Talos settings: the service and the component of the target cluster in the SSoT catalog, the Talos release, which MUST match the boot ISO under packer/output/talos-<version>/, the Kubernetes version, the KubePrism port, and the Gateway API CRD release pinned by digest."
  type = object({
    target_component = object({
      service   = string
      component = string
    })
    talos_version      = string
    kubernetes_version = string
    kubeprism_port     = optional(number, 7445)
    gateway_api = object({
      version = string
      sha256  = string
    })
  })
}

variable "helm_chart_version" {
  description = "Helm chart versions rendered into cluster.inlineManifests."
  type = object({
    cilium           = string
    cert_manager     = string
    external_secrets = string
  })
}
