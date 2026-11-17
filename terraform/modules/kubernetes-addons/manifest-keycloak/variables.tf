
variable "keycloak_config" {
  description = "Keycloak server. The hostname is the public FQDN which the issued tokens contain. The TLS Secret contains tls.crt and tls.key, and Keycloak serves HTTPS on https_port and the management interface on management_port. The resources apply to the server and to both init containers, and each map MUST set cpu and memory."
  type = object({
    namespace       = string
    image           = string
    hostname        = string
    tls_secret_name = string
    https_port      = optional(number, 8443)
    management_port = optional(number, 9000)
    resources = object({
      requests = map(string)
      limits   = map(string)
    })
  })

  validation {
    condition = alltrue([
      for quantity in [var.keycloak_config.resources.requests, var.keycloak_config.resources.limits] :
      contains(keys(quantity), "cpu") && contains(keys(quantity), "memory")
    ])
    error_message = "keycloak_config.resources MUST set cpu and memory in both requests and limits."
  }
}

variable "database_config" {
  description = "In-cluster PostgreSQL which stores the Keycloak database. The volume claim binds to storage_class_name."
  type = object({
    image              = string
    storage_class_name = string
    storage_size       = string
  })
}

variable "credential_secret" {
  description = "Secret in the Keycloak namespace which contains the bootstrap administrator and the database credentials, with the key name of each field."
  type = object({
    name               = string
    admin_user_key     = string
    admin_password_key = string
    db_user_key        = string
    db_password_key    = string
  })
}

variable "service_config" {
  description = "Service which publishes Keycloak on an address which is already assigned to a node, for example the Talos control plane VIP. Cilium kube-proxy replacement serves the externalIPs of a Service."
  type = object({
    external_ip = string
    port        = optional(number, 443)
  })
}
