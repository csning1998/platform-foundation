
variable "gitlab_terraform_state_base" {
  description = "Specifies the GitLab Terraform state API URL of the project hosting every state of this repository, without a trailing slash."
  type        = string

  validation {
    condition     = can(regex("^https://[^/]+/.+/projects/[0-9]+/terraform/state$", var.gitlab_terraform_state_base))
    error_message = "gitlab_terraform_state_base must match https://<host>/<api path>/projects/<project ID>/terraform/state."
  }
}

variable "helm_chart_version" {
  description = "Helm chart versions of the workloads which this layer installs. Required on the Talos runtime."
  type = object({
    local_path_provisioner = string
    vault                  = string
  })
  default = null
}

variable "vault_config" {
  description = "Vault server settings: the raft volume size of every server."
  type = object({
    storage_size = optional(string, "5Gi")
  })
  default = {}
}
