
locals {
  _state_base = var.gitlab_terraform_state_base
}

locals {
  state = {
    platform_cilium_hubble            = data.terraform_remote_state.platform_cilium_hubble.outputs
    foundation_libvirt_resources      = data.terraform_remote_state.foundation_libvirt_resources.outputs
    security_vault_downstream_tenants = data.terraform_remote_state.security_vault_downstream_tenants.outputs
  }
}

locals {
  cilium_hubble_cluster_issuer   = local.state.platform_cilium_hubble.talos_cluster.cluster_issuer
  cilium_hubble_external_secrets = local.state.platform_cilium_hubble.talos_cluster.external_secrets
  foundation_infrastructure_map  = local.state.foundation_libvirt_resources.foundation_topology.infrastructure
  foundation_project_code        = local.state.foundation_libvirt_resources.foundation_vault_path.project_code
}

locals {
  cilium_hubble_kubeconfig   = yamldecode(base64decode(ephemeral.vault_kv_secret_v2.cilium_hubble.data["content_b64"]))
  cilium_hubble_cluster_info = local.cilium_hubble_kubeconfig.clusters[0].cluster
  cilium_hubble_user_info    = local.cilium_hubble_kubeconfig.users[0].user

  cilium_hubble_api_server_connection = {
    host               = local.cilium_hubble_cluster_info.server
    ca_cert            = base64decode(local.cilium_hubble_cluster_info["certificate-authority-data"])
    client_certificate = base64decode(local.cilium_hubble_user_info["client-certificate-data"])
    client_key         = base64decode(local.cilium_hubble_user_info["client-key-data"])
  }
}

# Exclude the Cilium cluster segment from Service generation to prevent circular routing dependencies and self-referential load balancing.
locals {
  cilium_cluster_name = local.state.foundation_libvirt_resources.foundation_topology.identity["cilium"]["hubble"].cluster_name

  # Kubernetes-native runtimes only. Any other runtime is an external service owned end to
  # end by platform-haproxy-frontend, per the decisions.md entry retiring Cilium Service
  # exposure for non-Kubernetes backends. Registering both here and there double-owns the VIP.
  kubernetes_native_runtimes = local.state.foundation_libvirt_resources.foundation_topology.kubernetes_native_runtimes

  # Excludes entries missing an SSoT VIP (an open ADR defect) or a backend server, both
  # of which fail downstream against Cilium or the Kubernetes API.
  # A cluster tagged self-managed-lb holds its own VIP. An announcement of the VIP from this layer duplicates the holder.
  fronted_segments = {
    for key, seg in local.foundation_infrastructure_map : key => seg
    if key != local.cilium_cluster_name
    && !contains(seg.lb_config.tags, "self-managed-lb")
    && contains(local.kubernetes_native_runtimes, seg.runtime)
    && seg.lb_config.vip != null
    && length(seg.backend_servers) > 0
  }

  # Selector label binding generated Services to Cilium IPAM pools and L2 announcement
  # policies, isolating address allocations from unmanaged cluster workloads.
  lb_managed_label = {
    "platform.io/lb-managed" = "cilium-hubble"
  }
}

# The operator of this component logs in to the Downstream Vault with the JWT-SVID of the SPIRE Parent.
locals {
  terraform_operator_subject = { service = "cilium", component = "hubble" }
  terraform_operator         = local.state.security_vault_downstream_tenants.downstream_vault_operators[local.terraform_operator_subject.service][local.terraform_operator_subject.component]
}
