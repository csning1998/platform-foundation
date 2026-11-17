locals {
  _state_base = var.gitlab_terraform_state_base
}

locals {
  state = {
    foundation_libvirt_resources      = data.terraform_remote_state.foundation_libvirt_resources.outputs
    security_vault_downstream_tenants = data.terraform_remote_state.security_vault_downstream_tenants.outputs
    security_vault_downstream_pki     = data.terraform_remote_state.security_vault_downstream_pki.outputs
    platform_spire_parent             = data.terraform_remote_state.platform_spire_parent.outputs
    provision_spire_child             = data.terraform_remote_state.provision_spire_child.outputs
    provision_harbor_origin_frontend  = data.terraform_remote_state.provision_harbor_origin_frontend.outputs
  }
}

# Provider prerequisites: Must be defined as root-level locals because provider blocks cannot reference module outputs.
locals {
  downstream_vault_endpoint = "https://${local.state.security_vault_downstream_tenants.downstream_vault_service_vip}:443"
  vault_pki_cert_path       = local.state.security_vault_downstream_pki.bastion_pki_chain_b64.path
  harbor_registry_mirror    = local.state.provision_harbor_origin_frontend.harbor_registry_mirror
  downstream_kv_paths       = local.state.security_vault_downstream_tenants.foundation_vault_path.kv_paths
}

# The runtime of the component in the service catalog selects the VM path or the Talos path.
locals {
  keycloak_cluster_name    = module.terraform_layer_context.cluster_identity.cluster_name
  keycloak_cluster_runtime = local.state.foundation_libvirt_resources.foundation_topology.infrastructure[local.keycloak_cluster_name].runtime
  is_runtime_talos         = contains(local.state.foundation_libvirt_resources.foundation_topology.kubernetes_native_runtimes, local.keycloak_cluster_runtime)
}

# The operator of this component logs in to the Downstream Vault with the JWT-SVID of the SPIRE Parent.
locals {
  terraform_operator_subject = { service = "keycloak", component = "frontend" }
  terraform_operator         = local.state.security_vault_downstream_tenants.downstream_vault_operators[local.terraform_operator_subject.service][local.terraform_operator_subject.component]
}

# The inputs omit the project code, because cluster names derive from the foundation topology.
locals {
  target_clusters = {
    for role, c in var.target_components :
    role => local.state.foundation_libvirt_resources.foundation_topology.identity[c.service][c.component].cluster_name
  }
}
