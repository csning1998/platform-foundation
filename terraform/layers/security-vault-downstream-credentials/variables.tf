
variable "gitlab_terraform_state_base" {
  description = "Specifies the GitLab Terraform state API URL of the project hosting every state of the repository, without a trailing slash."
  type        = string

  validation {
    condition     = can(regex("^https://[^/]+/.+/projects/[0-9]+/terraform/state$", var.gitlab_terraform_state_base))
    error_message = "gitlab_terraform_state_base must match https://<host>/<api path>/projects/<project ID>/terraform/state."
  }
}

variable "keycloak_admin_user" {
  description = "Keycloak admin username (human-managed)."
  type        = string
  sensitive   = true
}

variable "keycloak_db_user" {
  description = "Keycloak database username (human-managed)."
  type        = string
  sensitive   = true
}
