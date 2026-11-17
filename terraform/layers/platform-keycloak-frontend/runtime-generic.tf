
# Declarations of the VM runtime alone. Each resource and module declares count = local.is_runtime_talos ? 0 : 1.
locals {
  # Configures VM Vault Agent workload authentication using SPIRE Child JWT-SVID credentials.
  tenant_login = local.state.security_vault_downstream_tenants.downstream_tenants.tenant_login[module.terraform_layer_context.cluster_identity.cluster_name]

  security_vault_agent_identity = merge(module.terraform_layer_context.vault_agent_identity_base, {
    auth_path      = local.tenant_login.auth_mount
    auth_role_name = local.tenant_login.role_name
  })

  spire_parent       = local.state.platform_spire_parent.spire_agent_bootstrap
  spiffe_workload_id = "spiffe://${local.spire_parent.trust_domain}/${local.state.security_vault_downstream_tenants.foundation_vault_path.project_code}/${module.terraform_layer_context.primary_context.s_name}/${module.terraform_layer_context.primary_context.c_name}"

  ansible_template_vars = {
    service_identifier      = module.terraform_layer_context.primary_context.s_name
    keycloak_fqdn           = module.terraform_layer_context.cluster_fqdn
    keycloak_service_domain = module.terraform_layer_context.cluster_identity.cluster_name
    keycloak_vip            = module.terraform_layer_context.primary_network_config.lb_config.vip
    keycloak_port           = module.terraform_layer_context.primary_network_config.lb_config.ports["https"].frontend_port
    keycloak_node_subnet    = module.terraform_layer_context.primary_network_config.network.hostonly.cidr
    vault_vip               = module.terraform_layer_context.downstream_vault_service_vip
    global_mss              = module.terraform_layer_context.global_mss

    infra_keycloak_cluster_ips = [
      for comp_name, comp_config in var.service_config : [
        for node_suffix, node_data in comp_config.nodes :
        cidrhost(module.terraform_layer_context.primary_network_config.network.hostonly.cidr, node_data.ip_suffix)
      ]
    ][0]

    access_scope = module.terraform_layer_context.primary_network_config.network.hostonly.cidr
    service_name = module.terraform_layer_context.primary_context.s_name
  }

  # Vault access configuration for Ansible operator login and secret retrieval.
  vault_access = {
    downstream = {
      endpoint     = local.state.security_vault_downstream_tenants.downstream_vault_endpoint
      ca_cert_path = local.state.security_vault_downstream_tenants.downstream_vault_ca_cert_path
      auth_mount   = local.terraform_operator.auth_mount
      role         = local.terraform_operator.role_name
      wrapper      = local.terraform_operator.wrapper_name
    }
  }

  ansible_extra_vars = {
    keycloak_credential_kv_path = local.downstream_kv_paths["keycloak"]["frontend"].app
    vault_access                = jsonencode(local.vault_access)

    spire_trust_domain             = local.spire_parent.trust_domain
    spire_workload_spiffe_id       = local.spiffe_workload_id
    spire_cluster_name             = module.terraform_layer_context.cluster_identity.cluster_name
    spire_child_join_token_kv_path = local.state.security_vault_downstream_tenants.foundation_vault_path.kv_paths["spire"]["child"].join_token

    spire_child_agent_address      = local.state.provision_spire_child.spire_child_agent_endpoint.address
    spire_child_agent_port         = tostring(local.state.provision_spire_child.spire_child_agent_endpoint.port)
    spire_child_kubeconfig_kv_path = local.state.provision_spire_child.spire_child_registrar_kv_path
    vault_agent_jwt_audience       = local.tenant_login.audience

    vault_agent_common_name = local.security_vault_agent_identity.common_name
    # The join tokens and the registrar kubeconfig of the SPIRE Child live in the Downstream KV.
    operator_vault_url          = local.state.security_vault_downstream_tenants.downstream_vault_endpoint
    operator_vault_ca_cert_path = local.state.security_vault_downstream_tenants.downstream_vault_ca_cert_path
    # The Downstream Vault takes no Proxy client certificate.
    operator_vault_client_cert = ""
    operator_vault_client_key  = ""
    operator_vault_wrapper     = local.terraform_operator.wrapper_name
    operator_vault_role        = local.terraform_operator.role_name
    operator_vault_auth_mount  = local.terraform_operator.auth_mount
  }
}

module "establish_platform_keycloak_generic_cluster" {
  source = "../../modules/kvm-provisioning/orchestrate/linux-generic-cluster"

  count             = local.is_runtime_talos ? 0 : 1
  ansible_root_path = local.state.foundation_libvirt_resources.foundation_paths.ansible_root
  scripts_root_path = local.state.foundation_libvirt_resources.foundation_paths.scripts_root

  cluster_identity              = module.terraform_layer_context.cluster_identity
  node_identities               = module.terraform_layer_context.node_identities
  topology_cluster              = module.terraform_layer_context.topology_cluster
  network_infrastructure_map    = module.terraform_layer_context.network_infrastructure_map
  storage_infrastructure_map    = local.state.foundation_libvirt_resources.foundation_storage.infrastructure
  security_vault_agent_identity = local.security_vault_agent_identity
  ssh_config_path               = local.state.foundation_libvirt_resources.foundation_ssh.config_paths[module.terraform_layer_context.cluster_identity.cluster_name]

  # Guest authentication MUST combine cluster-specific SSH keypairs from foundation resources
  # with shared baseline credentials from Vault storage.
  credentials_system = merge(module.terraform_layer_context.security_vm_credentials, {
    ssh_private_key_path = local.state.foundation_libvirt_resources.foundation_ssh.identity_key_paths[module.terraform_layer_context.cluster_identity.cluster_name]
    ssh_public_key_path  = local.state.foundation_libvirt_resources.foundation_ssh.public_key_paths[module.terraform_layer_context.cluster_identity.cluster_name]
  })
  ansible_generic_config = {
    template_vars = local.ansible_template_vars
    extra_vars    = local.ansible_extra_vars
  }
}
