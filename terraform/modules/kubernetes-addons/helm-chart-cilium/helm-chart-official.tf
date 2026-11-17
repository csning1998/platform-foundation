
locals {
  gateway_api_enabled = var.cilium_config.gateway_api != null

  # The mTLS certificates of the Hubble server and relay gRPC endpoints contain these names.
  hubble_tls_domains = ["hubble-grpc.cilium.io", "hubble-relay.cilium.io"]

  # The chart renders a second privateKey key after hubble.tls.auto.privateKey, which drops the ECDSA algorithm.
  # The caller therefore issues the Secrets which the chart mounts. The server name includes the cluster.name default.
  hubble_tls_certificates = {
    "hubble-server-certs" = {
      common_name = "*.default.hubble-grpc.cilium.io"
      usages      = ["digital signature", "server auth", "client auth"]
    }
    "hubble-relay-client-certs" = {
      common_name = "*.hubble-relay.cilium.io"
      usages      = ["digital signature", "client auth"]
    }
  }

  hubble = merge(
    { enabled = var.hubble_config.enabled },
    {
      for key, value in {
        relay = { enabled = true, tls = { client = { existingSecret = "hubble-relay-client-certs" } } }
        ui    = { enabled = true }
        tls = {
          auto   = { enabled = false }
          server = { existingSecret = "hubble-server-certs" }
        }
      } : key => value if var.hubble_config.enabled
    }
  )
}

# The chart renders to a manifest, since Talos applies the CNI as an inline manifest before the API server exists.
data "helm_template" "cilium" {
  name         = "cilium"
  namespace    = "kube-system"
  chart        = "${var.helm_config.chart_repository}/cilium"
  version      = var.helm_config.version
  kube_version = var.helm_config.kubernetes_version

  # Talos denies the SYS_MODULE capability to workloads. The host provisions cgroupv2 and bpffs mounts.
  values = [yamlencode({
    kubeProxyReplacement = true
    ipam                 = { mode = "kubernetes" }
    l2announcements      = { enabled = true }
    operator             = { replicas = min(2, var.cilium_config.node_count) }
    hubble               = local.hubble

    # The Gateway API CRDs are delivered as an inline manifest of the same machine configuration, and the Cilium operator reads the CRDs at start.
    gatewayAPI = { enabled = local.gateway_api_enabled }

    MTU = var.cilium_config.mtu

    # Retained as the configuration validated for in-cluster traffic. The setting does not resolve SNAT toward external backends, which HAProxy serves instead.
    bpf = { masquerade = true }

    # Route API server connections to node-local KubePrism endpoints. Disabling kube-proxy
    # prevents ClusterIP routing prior to CNI initialization.
    k8sServiceHost = "localhost"
    k8sServicePort = var.cilium_config.kubeprism_port

    cgroup = {
      autoMount = { enabled = false }
      hostRoot  = "/sys/fs/cgroup"
    }

    securityContext = {
      capabilities = {
        ciliumAgent = [
          "CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN",
          "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID",
        ]
        cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
      }
    }
  })]
}

data "http" "gateway_api_crds" {
  count = local.gateway_api_enabled ? 1 : 0
  url   = "https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.cilium_config.gateway_api.version}/standard-install.yaml"

  lifecycle {
    postcondition {
      condition     = sha256(self.response_body) == var.cilium_config.gateway_api.sha256
      error_message = "The Gateway API ${var.cilium_config.gateway_api.version} standard-install.yaml does not match the pinned digest."
    }
  }
}
