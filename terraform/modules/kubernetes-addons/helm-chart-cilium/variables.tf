
variable "helm_config" {
  description = "Helm chart render parameters. The chart_repository is the OCI repository which stores the chart, for example the Harbor Origin project of the replicated charts. The kubernetes_version overrides the provider default for the chart constraint check."
  type = object({
    chart_repository   = string
    version            = string
    kubernetes_version = string
  })
}

variable "cilium_config" {
  description = "Cilium values. The operator replica count follows node_count up to two, since the chart places replicas on separate nodes. The VXLAN overhead of 50 bytes yields a pod route MTU of mtu minus 50. A null gateway_api disables the Gateway API, and its digest pins the downloaded standard-install.yaml."
  type = object({
    kubeprism_port = optional(number, 7445)
    node_count     = number
    mtu            = number
    gateway_api = optional(object({
      version = string
      sha256  = string
    }))
  })
}

variable "hubble_config" {
  description = "Hubble settings. An enabled Hubble mounts the Secrets of the hubble_tls_certificates output, which the caller MUST issue."
  type = object({
    enabled = optional(bool, false)
  })
  default = {}
}
