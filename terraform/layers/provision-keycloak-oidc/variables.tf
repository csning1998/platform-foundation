
variable "gitlab_terraform_state_base" {
  description = "Specifies the GitLab Terraform state API URL of the project hosting every state of the repository, without a trailing slash."
  type        = string

  validation {
    condition     = can(regex("^https://[^/]+/.+/projects/[0-9]+/terraform/state$", var.gitlab_terraform_state_base))
    error_message = "gitlab_terraform_state_base must match https://<host>/<api path>/projects/<project ID>/terraform/state."
  }
}

variable "oidc_users" {
  description = "Map of users to create in Keycloak with their associated groups"
  type = map(object({
    username   = string
    email      = string
    first_name = string
    last_name  = string
    password   = string
    groups     = list(string)
  }))
  default = {}
}

variable "talos_workload_config" {
  description = "Keycloak workload of the Talos runtime. The images match the VM runtime by tag and include the digest of the tag, and the nodes pull them through the Harbor Origin mirrors. The local-path chart comes from its upstream OCI repository, as on the Downstream Vault."
  type = object({
    keycloak_image = string
    keycloak_resources = object({
      requests = map(string)
      limits   = map(string)
    })
    postgres_image                          = string
    database_storage_size                   = string
    local_path_provisioner_chart_repository = string
    local_path_provisioner_chart_version    = string
  })
  # The Talos node of Keycloak has 2 vCPU and also runs the control plane and PostgreSQL, hence the CPU limit of 1.5 cores.
  default = {
    keycloak_image = "quay.io/keycloak/keycloak:26.6.1@sha256:dea26401d06341095cc4ea9d66896200b55de5ca1daa1d2fcbe58493afa6e0ad"
    keycloak_resources = {
      requests = { cpu = "250m", memory = "768Mi" }
      limits   = { cpu = "1500m", memory = "1536Mi" }
    }
    postgres_image                          = "docker.io/library/postgres:18-alpine@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873"
    database_storage_size                   = "10Gi"
    local_path_provisioner_chart_repository = "oci://ghcr.io/rancher/local-path-provisioner/charts"
    local_path_provisioner_chart_version    = "0.0.37"
  }

  validation {
    condition = alltrue([
      for image in [var.talos_workload_config.keycloak_image, var.talos_workload_config.postgres_image] :
      can(regex("@sha256:[0-9a-f]{64}$", image))
    ])
    error_message = "keycloak_image and postgres_image MUST include a sha256 digest."
  }
}

variable "client_role_grants" {
  description = "Roles of each OIDC client, keyed by the client key of the layer, with the organization groups which receive each role. The service of a client reads the roles claim and maps each role name to its own permission."
  type        = map(map(list(string)))
  default     = {}
}

variable "keycloak_groups" {
  description = "Hierarchical group definitions with parents and attributes."
  type = map(object({
    parent      = optional(string, null)
    attributes  = optional(map(string), {})
    description = optional(string, "")
  }))
  default = {}
}
