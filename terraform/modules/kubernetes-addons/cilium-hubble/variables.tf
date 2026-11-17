
variable "hubble_ui_config" {
  description = "Hubble UI exposure parameters: the namespace of the ingress objects, the public hostname, the Gateway VIP, the login user, and the KV path of the login credentials."
  type = object({
    namespace   = string
    hostname    = string
    gateway_vip = string
    kv_path     = string
    login_user  = optional(string, "hubble")
    upstream    = optional(string, "http://hubble-ui.kube-system.svc.cluster.local:80")
  })
}

variable "gateway_config" {
  description = "Gateway API and certificate parameters: the GatewayClass, the ClusterIssuer reference, the ClusterSecretStore, and the name of the Cilium IP pool and L2 announcement policy."
  type = object({
    class_name        = string
    secret_store_name = string
    lb_policy_name    = string
    issuer_ref = object({
      name  = string
      kind  = string
      group = string
    })
  })
}

variable "oauth2_proxy_config" {
  description = "oauth2-proxy container parameters. The image reference MUST include a digest."
  type = object({
    image = string
    port  = number
  })
  default = {
    image = "quay.io/oauth2-proxy/oauth2-proxy:v7.15.4@sha256:b1b2021fe8f4004573e8d690dec6c7bb29cc44364572cf8510a05bf3a0ae2ded"
    port  = 4180
  }
}
