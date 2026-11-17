
locals {
  _state_base = var.gitlab_terraform_state_base
}

locals {
  state = {
    foundation_libvirt_resources      = data.terraform_remote_state.foundation_libvirt_resources.outputs
    security_vault_downstream_tenants = data.terraform_remote_state.security_vault_downstream_tenants.outputs
    security_vault_downstream_pki     = data.terraform_remote_state.security_vault_downstream_pki.outputs
    provision_harbor_origin_frontend  = data.terraform_remote_state.provision_harbor_origin_frontend.outputs
  }
}

locals {
  foundation_kv_paths = local.state.foundation_libvirt_resources.foundation_vault_path.kv_paths["cilium"]["hubble"]
  downstream_kv_paths = local.state.security_vault_downstream_tenants.foundation_vault_path.kv_paths["cilium"]["hubble"]
}

# Provider prerequisites: Must be defined as root-level locals because provider blocks cannot reference module outputs.
locals {
  downstream_vault_endpoint = local.state.security_vault_downstream_tenants.downstream_vault_endpoint
  vault_pki_cert_path       = local.state.security_vault_downstream_tenants.downstream_vault_ca_cert_path
  harbor_robot_kv_path      = local.state.security_vault_downstream_tenants.foundation_vault_path.kv_paths["harbor-origin"]["frontend"].robot
  harbor_registry_mirror    = local.state.provision_harbor_origin_frontend.harbor_registry_mirror
}

# segments_map is reused from platform-haproxy-frontend.
# The service catalog owns segments_map. HAProxy and Cilium only consume segments_map.
locals {
  network_segments_map = merge([
    for s_name, components in local.state.foundation_libvirt_resources.foundation_topology.identity : {
      for c_name, identity in components : identity.cluster_name => {
        identity = identity
        network  = local.state.foundation_libvirt_resources.foundation_topology.network[s_name][c_name]
        vip      = lookup(local.state.foundation_libvirt_resources.foundation_topology.infrastructure, identity.cluster_name, { lb_config = { vip = null } }).lb_config.vip
        s_name   = s_name
        c_name   = c_name
      }
    }
  ]...)


  network_map = { for k, v in local.network_segments_map : k => v.network }

  cilium_hubble_cluster_name     = local.state.foundation_libvirt_resources.foundation_topology.identity[var.talos_config.target_component.service][var.talos_config.target_component.component].cluster_name
  cilium_hubble_cluster_context  = local.network_segments_map[local.cilium_hubble_cluster_name]
  cilium_hubble_cluster_identity = local.cilium_hubble_cluster_context.identity
  cilium_hubble_cluster_pki      = local.state.foundation_libvirt_resources.foundation_pki.map["${local.cilium_hubble_cluster_context.s_name}-${local.cilium_hubble_cluster_context.c_name}"]

  # network_service_segments excludes the CLB cluster, which lacks an SSoT reservation.
  # The same defect exists on platform-haproxy-frontend and remains open.
  network_service_segments = [
    for name, seg in local.state.foundation_libvirt_resources.foundation_topology.segments : seg
    if seg.name != local.cilium_hubble_cluster_name && !contains(seg.tags, "self-managed-lb")
  ]

  # Each node takes the address at its position in the sorted node keys from the foundation derivation.
  bastion_network_nodes = {
    for idx, key in sort(keys(var.node_config)) : key => {
      (local.state.foundation_libvirt_resources.foundation_bastion_network.network_name) = local.state.foundation_libvirt_resources.foundation_bastion_network.addresses[local.cilium_hubble_cluster_name][idx]
    }
  }
}

# The operator of this component logs in to the Downstream Vault with the JWT-SVID of the SPIRE Parent.
locals {
  terraform_operator_subject = { service = "cilium", component = "hubble" }
  terraform_operator         = local.state.security_vault_downstream_tenants.downstream_vault_operators[local.terraform_operator_subject.service][local.terraform_operator_subject.component]
}
