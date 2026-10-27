
# GitLab HTTP backend base URL. Authentication credentials must be supplied via
# `TF_HTTP_USERNAME` and `TF_HTTP_PASSWORD` environment variables.
locals {
  _state_base_platform_foundation = "https://gitlab.com/api/v4/projects/84608830/terraform/state"
}

locals {
  state = {
    foundation_libvirt_resources = data.terraform_remote_state.foundation_libvirt_resources.outputs
  }
}

# Each registry field holds one category in JSON. The facts are not secret, while the provider marks every KV value as sensitive.
locals {
  registry_bastion = {
    for field, value in nonsensitive(data.vault_generic_secret.registry_bastion.data) : field => jsondecode(value)
  }
  stage_domains = jsondecode(nonsensitive(data.vault_generic_secret.registry_platform_network_allocation.data["stage_domains"]))

  bastion_pki_spire    = local.registry_bastion.pki.constrained_intermediates["pki-intermediate-spire"]
  bastion_pki_platform = local.registry_bastion.pki.constrained_intermediates["pki-leaf-platform"]

  bastion_pki_spire_cert_pem    = local.bastion_pki_spire.issuer_certs[local.bastion_pki_spire.root_ca_id]
  bastion_pki_platform_cert_pem = local.bastion_pki_platform.issuer_certs[local.bastion_pki_platform.root_ca_id]
}

locals {
  foundation_project_code = local.state.foundation_libvirt_resources.foundation_vault_path.project_code

  # Extracts the SPIRE trust domain ("<stage>.<domain_suffix>") from module.terraform_layer_context.cluster_fqdn.
  # Asserts structural alignment with "<service_name>.<stage>.<domain_suffix>".
  # Pattern mismatches MUST trigger plan-time evaluation failure to prevent invalid trust domain propagation.
  spiffe_trust_domain  = regex("^[^.]+\\.(${module.terraform_layer_context.cluster_identity.stage}\\..+)$", module.terraform_layer_context.cluster_fqdn)[0]
  spire_server_port    = module.terraform_layer_context.primary_network_config.lb_config.ports.api.frontend_port
  spire_oidc_port      = module.terraform_layer_context.primary_network_config.lb_config.ports.oidc.frontend_port
  spire_parent_node_ip = one(module.terraform_layer_context.cluster_network.node_ips)

  # Documentation: documentation/architecture/platform-spire-parent-frontend.md Section 1 Item C.
  oidc_ca_chain_pem = "${trimspace(local.registry_bastion.pki.trust_anchors[local.bastion_pki_platform.root_ca_id])}\n${trimspace(local.bastion_pki_platform_cert_pem)}\n"

  # k8s:psat node attestation configures trusted ServiceAccount allowlists for downstream SPIRE child clusters.
  spire_child_k8s_psat_clusters = [
    for c_name, identity in local.state.foundation_libvirt_resources.foundation_topology.identity["spire"] : {
      name                       = identity.cluster_name
      service_account_allow_list = ["spire-system:spire-agent-upstream"]
    }
    if contains(local.state.foundation_libvirt_resources.foundation_topology.kubernetes_native_runtimes, local.state.foundation_libvirt_resources.foundation_topology.infrastructure[identity.cluster_name].runtime)
  ]

  ansible_template_config = {
    global_mss                = module.terraform_layer_context.global_mss
    spire_parent_vip          = module.terraform_layer_context.primary_network_config.lb_config.vip
    spire_parent_cluster_name = module.terraform_layer_context.cluster_identity.cluster_name
    spire_parent_node_ip      = local.spire_parent_node_ip
    spire_trust_domain        = local.spiffe_trust_domain
    spire_server_port         = local.spire_server_port
    spire_oidc_discovery_port = local.spire_oidc_port
    spire_k8s_psat_clusters   = jsonencode(local.spire_child_k8s_psat_clusters)

    # Documentation: documentation/architecture/platform-spire-parent-frontend.md Section 4 Item B.
    spire_oidc_domain = local.spire_parent_node_ip
  }

  # Every value is public. Ansible issues the secret ID and the listener key through the Vault Proxy, outside the state.
  ansible_extra_config = {
    ansible_user = module.terraform_layer_context.security_vm_credentials.username

    spire_vault_upstream_addr                  = local.registry_bastion.vault.endpoint
    spire_vault_upstream_pki_mount_path        = local.bastion_pki_spire.mount_path
    spire_vault_upstream_approle_mount_path    = local.registry_bastion.vault.approle_mount_path
    spire_vault_upstream_role_name             = vault_approle_auth_backend_role.spire_parent_upstream_authority.role_name
    spire_vault_upstream_role_id               = vault_approle_auth_backend_role.spire_parent_upstream_authority.role_id
    spire_vault_upstream_ca_cert_b64           = base64encode(local.registry_bastion.vault.listener_ca_cert_pem)
    spire_oidc_pki_mount_path                  = vault_pki_secret_backend_role.oidc_discovery.backend
    spire_oidc_pki_role_name                   = vault_pki_secret_backend_role.oidc_discovery.name
    spire_oidc_common_name                     = module.terraform_layer_context.cluster_fqdn
    spire_oidc_ip_sans                         = join(",", module.terraform_layer_context.cluster_network.node_ips)
    spire_oidc_ca_chain_b64                    = base64encode(local.oidc_ca_chain_pem)
    spire_parent_trust_domain_reinitialization = var.spire_trust_domain_reinitialization
  }
}

# Cluster names derive from the foundation topology, so no input carries the project code.
locals {
  target_clusters = {
    for role, c in var.target_components :
    role => local.state.foundation_libvirt_resources.foundation_topology.identity[c.service][c.component].cluster_name
  }
}
