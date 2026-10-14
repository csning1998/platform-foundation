
variable "tenants" {
  description = "Platform tenant workloads keyed by the name below the project code, each mapping a SPIFFE ID to a JWT auth role and KV and PKI ACL policies. workload names a catalog service and component, and kubernetes names a namespace and a service account, and exactly one of the two MUST be set. kv_paths, kv_read_paths, and pki_roles are relative to the project code. issuer child binds a workload attested by the SPIRE Child, and provision-spire-child creates its role. issuer parent binds a workload attested by the SPIRE Parent, and this layer creates its role. External owners register their own workloads, see _external_owners."
  type = map(object({
    issuer = optional(string, "child")
    workload = optional(object({
      service   = string
      component = string
    }))
    kubernetes = optional(object({
      namespace       = string
      service_account = string
    }))
    kv_paths      = optional(list(string), [])
    kv_read_paths = optional(list(string), [])
    pki_roles     = optional(list(string), [])
  }))
  default = {}

  validation {
    condition     = alltrue([for t in var.tenants : (t.workload == null) != (t.kubernetes == null)])
    error_message = "Every tenant MUST set exactly one of workload and kubernetes."
  }

  validation {
    condition     = alltrue([for t in var.tenants : contains(["parent", "child"], t.issuer)])
    error_message = "The issuer MUST be parent or child."
  }
}
