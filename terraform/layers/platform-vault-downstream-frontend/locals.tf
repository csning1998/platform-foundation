
locals {
  _state_base = var.gitlab_terraform_state_base
}

locals {
  state = {
    foundation_libvirt_resources = data.terraform_remote_state.foundation_libvirt_resources.outputs
  }
  foundation_project_code = local.state.foundation_libvirt_resources.foundation_vault_path.project_code
}

# Each registry field holds one category in JSON. The facts are not secret, while the provider marks every KV value as sensitive.
locals {
  registry_bastion = {
    for field, value in nonsensitive(data.vault_generic_secret.registry_bastion.data) : field => jsondecode(value)
  }
  bastion_pki_platform          = local.registry_bastion.pki.constrained_intermediates["pki-leaf-platform"]
  bastion_pki_platform_cert_pem = local.bastion_pki_platform.issuer_certs[local.bastion_pki_platform.root_ca_id]

  # The listener of the Downstream Vault chains to the Bastion root through pki-leaf-platform.
  listener_ca_chain_pem = "${trimspace(local.registry_bastion.pki.trust_anchors[local.bastion_pki_platform.root_ca_id])}\n${trimspace(local.bastion_pki_platform_cert_pem)}\n"
}

# The runtime of the component in the service catalog selects the declarations of runtime-talos.tf or runtime-vm.tf.
locals {
  vault_downstream_cluster_name    = module.terraform_layer_context.cluster_identity.cluster_name
  vault_downstream_cluster_runtime = local.state.foundation_libvirt_resources.foundation_topology.infrastructure[local.vault_downstream_cluster_name].runtime
  foundation_kv_paths              = local.state.foundation_libvirt_resources.foundation_vault_path.kv_paths["vault-downstream"]["frontend"]
  is_runtime_talos                 = contains(local.state.foundation_libvirt_resources.foundation_topology.kubernetes_native_runtimes, local.vault_downstream_cluster_runtime)
}

# The inputs omit the project code, because cluster names derive from the foundation topology.
locals {
  target_clusters = {
    for role, c in var.target_components :
    role => local.state.foundation_libvirt_resources.foundation_topology.identity[c.service][c.component].cluster_name
  }
}
