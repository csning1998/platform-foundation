
variable "certificate_config" {
  description = "cert-manager Certificate. The Secret has the same name as the Certificate. The usages default to a server certificate which also authenticates as a client."
  type = object({
    name         = string
    namespace    = string
    common_name  = string
    dns_names    = optional(list(string), [])
    ip_addresses = optional(list(string), [])
    usages       = optional(list(string), ["digital signature", "server auth", "client auth"])
    duration     = optional(string, "720h")
    renew_before = optional(string, "240h")
  })
}

variable "issuer_ref" {
  description = "Reference of the issuer which signs the Certificate, in the shape of the cluster_issuer_ref output of vault-kubernetes-auth."
  type = object({
    group = optional(string, "cert-manager.io")
    kind  = optional(string, "ClusterIssuer")
    name  = string
  })
}
