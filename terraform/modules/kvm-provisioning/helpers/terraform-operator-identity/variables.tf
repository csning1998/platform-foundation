
variable "operator_identity_config" {
  description = "Terraform operators which one SPIRE server attests. server names that server. targets maps each operator key to the owner code, the catalog service, and the catalog component of the operator. topology_identity is the foundation topology identity, which supplies the cluster name of each component."
  type = object({
    server = string
    targets = map(object({
      owner     = string
      service   = string
      component = string
    }))
    topology_identity = map(map(object({
      cluster_name = string
    })))
  })

  validation {
    condition     = contains(["parent", "child"], var.operator_identity_config.server)
    error_message = "operator_identity_config.server MUST be parent or child."
  }
}
