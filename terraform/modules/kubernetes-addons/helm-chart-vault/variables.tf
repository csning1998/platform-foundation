
variable "helm_config" {
  description = "Helm release parameters. HashiCorp publishes the chart only in the HTTP repository https://helm.releases.hashicorp.com. The namespace MUST exist, since the TLS Secret precedes the release."
  type = object({
    chart_repository = string
    version          = string
    namespace        = string
    timeout          = optional(number, 600)
  })
}

# The raft settings are separate from vault_config because the listener certificate reads listener_names before the TLS Secret exists.
variable "raft_config" {
  description = "Raft cluster settings: the number of servers, which form one raft cluster, and the cluster domain under which the peers join."
  type = object({
    replicas       = number
    cluster_domain = optional(string, "cluster.local")
  })

  validation {
    condition     = var.raft_config.replicas % 2 == 1
    error_message = "raft_config.replicas MUST be odd for the raft quorum."
  }
}

variable "vault_config" {
  description = "Vault server settings. The init container of the transit seal runs the server image, hence one image_tag pins both. The TLS Secret contains tls.crt, tls.key, and ca.crt, and its certificate MUST contain the dns_names of the output listener_names for the CLI inside each server and the raft join."
  type = object({
    tls_secret_name = string
    storage_class   = string
    storage_size    = optional(string, "10Gi")
    service_account = optional(string, "vault")
    image_tag       = optional(string, "2.0.4")
  })
}

variable "service_config" {
  description = "Service which publishes the active Vault server on an address which is already assigned to a node, for example the Talos control plane VIP. Cilium kube-proxy replacement serves the externalIPs of a Service."
  type = object({
    external_ip = string
    port        = optional(number, 443)
  })
}

variable "transit_seal_config" {
  description = "Transit seal against an upstream Vault. An init container logs in with a projected ServiceAccount token of the given audience and writes the seal stanza with the issued token to a memory volume, which the server reads through an extra -config. Null keeps the Shamir seal."
  type = object({
    address     = string
    ca_cert_pem = string
    auth_path   = string
    role_name   = string
    audience    = string
    mount_path  = string
    key_name    = string
  })
  default = null
}
