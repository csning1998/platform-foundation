
variable "gitlab_terraform_state_base" {
  description = "Specifies the GitLab Terraform state API URL of the project hosting every state of this repository, without a trailing slash."
  type        = string

  validation {
    condition     = can(regex("^https://[^/]+/.+/projects/[0-9]+/terraform/state$", var.gitlab_terraform_state_base))
    error_message = "gitlab_terraform_state_base must match https://<host>/<api path>/projects/<project ID>/terraform/state."
  }
}

variable "spire_crds_chart_version" {
  description = "Helm chart version for spire-crds CustomResourceDefinitions."
  type        = string
}

variable "spire_nested_chart_version" {
  description = "Helm chart version for spire-nested. AppVersion MUST match the parent SPIRE server release."
  type        = string
}

variable "local_path_provisioner_chart_version" {
  description = "Helm chart version for local-path-provisioner, which serves the datastore claim of the SPIRE Child server."
  type        = string
}

variable "spire_child_ca_subject_country" {
  description = "Country code for child SPIRE server intermediate CA certificate subject."
  type        = string
}
