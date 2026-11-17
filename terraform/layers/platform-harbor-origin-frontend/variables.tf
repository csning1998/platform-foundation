
variable "gitlab_terraform_state_base" {
  description = "Specifies the GitLab Terraform state API URL of the project hosting every state of the repository, without a trailing slash."
  type        = string

  validation {
    condition     = can(regex("^https://[^/]+/.+/projects/[0-9]+/terraform/state$", var.gitlab_terraform_state_base))
    error_message = "gitlab_terraform_state_base must match https://<host>/<api path>/projects/<project ID>/terraform/state."
  }
}

variable "primary_role" {
  description = "Primary role key within target_components."
  type        = string
}

variable "service_config" {
  description = "Compute topology per role for Harbor Origin service."
  type = map(object({
    role            = string
    network_tier    = optional(string, "default")
    base_image_path = string
    nodes = map(object({
      ip_suffix            = number
      vcpu                 = number
      ram_size             = number
      os_disk_capacity_gib = optional(number)
      extra_networks       = optional(map(string), {})
    }))
  }))
}

variable "target_components" {
  description = "Map of role to the service and the component of the SSoT catalog. The layer resolves each pair to the cluster name of the foundation topology."
  type = map(object({
    service   = string
    component = string
  }))
}
