
locals {
  _state_base = var.gitlab_terraform_state_base
}

locals {
  state = {
    foundation_libvirt_resources      = data.terraform_remote_state.foundation_libvirt_resources.outputs
    platform_spire_parent             = data.terraform_remote_state.platform_spire_parent.outputs
    security_vault_downstream_pki     = data.terraform_remote_state.security_vault_downstream_pki.outputs
    security_vault_downstream_tenants = data.terraform_remote_state.security_vault_downstream_tenants.outputs
    provision_spire_child             = data.terraform_remote_state.provision_spire_child.outputs
  }
}

# The operator of this component logs in to the Downstream Vault with the JWT-SVID of the SPIRE Parent.
locals {
  terraform_operator_subject = { service = "harbor-origin", component = "frontend" }
  terraform_operator         = local.state.security_vault_downstream_tenants.downstream_vault_operators[local.terraform_operator_subject.service][local.terraform_operator_subject.component]
  tenant_login               = local.state.security_vault_downstream_tenants.downstream_tenants.tenant_login[module.terraform_layer_context.cluster_identity.cluster_name]

  security_vault_agent_identity = merge(module.terraform_layer_context.vault_agent_identity_base, {
    auth_path      = local.tenant_login.auth_mount
    auth_role_name = local.tenant_login.role_name
  })
}

# Requires inclusion of the catalog service VIP within the certificate IP SAN to support the HAProxy-fronted VIP.
locals {
  harbor_node_ips = flatten([
    for comp_name, comp_config in var.service_config : [
      for node_suffix, node_data in comp_config.nodes :
      cidrhost(module.terraform_layer_context.primary_network_config.network.hostonly.cidr, node_data.ip_suffix)
    ]
  ])

  # Bootstrap listener endpoints MUST bind to the lowest numerical IP address
  # to guarantee deterministic configuration across non-ordered map iterations.
  harbor_listen_ip = sort(local.harbor_node_ips)[0]

  downstream_pki_listener_bundle = {
    server_cert_b64 = base64encode(vault_pki_secret_backend_cert.listener.certificate)
    server_key_b64  = base64encode(vault_pki_secret_backend_cert.listener.private_key)
    ca_cert_b64     = module.terraform_layer_context.vault_agent_identity_base.ca_cert_b64
  }

  spiffe_workload_id = "spiffe://${local.state.platform_spire_parent.spire_agent_bootstrap.trust_domain}/${local.state.foundation_libvirt_resources.foundation_vault_path.project_code}/${module.terraform_layer_context.primary_context.s_name}/${module.terraform_layer_context.primary_context.c_name}"
}

locals {
  ansible_template_vars = {
    global_mss                     = module.terraform_layer_context.global_mss
    access_scope                   = module.terraform_layer_context.primary_network_config.network.hostonly.cidr
    service_name                   = module.terraform_layer_context.primary_context.s_name
    service_identifier             = module.terraform_layer_context.primary_context.s_name
    harbor_origin_fqdn             = module.terraform_layer_context.cluster_fqdn
    harbor_origin_service_domain   = module.terraform_layer_context.cluster_identity.cluster_name
    harbor_origin_mtls_node_subnet = module.terraform_layer_context.primary_network_config.network.hostonly.cidr
    harbor_origin_vip              = module.terraform_layer_context.primary_network_config.lb_config.vip
    harbor_origin_tls_port         = module.terraform_layer_context.primary_network_config.lb_config.ports["https"].frontend_port
    harbor_origin_metrics_port     = module.terraform_layer_context.primary_network_config.lb_config.ports["metrics"].frontend_port
    harbor_origin_listen_address   = local.harbor_listen_ip
    harbor_origin_cluster_ips      = local.harbor_node_ips
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
    harbor_origin_credential_kv_path = local.state.foundation_libvirt_resources.foundation_vault_path.kv_paths["harbor-origin"]["frontend"].app
    vault_access                     = jsonencode(local.vault_access)

    spire_trust_domain             = local.state.platform_spire_parent.spire_agent_bootstrap.trust_domain
    spire_workload_spiffe_id       = local.spiffe_workload_id
    spire_cluster_name             = module.terraform_layer_context.cluster_identity.cluster_name
    spire_child_join_token_kv_path = local.state.foundation_libvirt_resources.foundation_vault_path.kv_paths["spire"]["child"].join_token
    spire_child_agent_address      = local.state.provision_spire_child.spire_child_agent_endpoint.address
    spire_child_agent_port         = tostring(local.state.provision_spire_child.spire_child_agent_endpoint.port)
    spire_child_kubeconfig_kv_path = local.state.provision_spire_child.spire_child_registrar_kv_path
    vault_agent_jwt_audience       = local.tenant_login.audience

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

# Target cluster names derive from the foundation topology to keep inputs free of project codes.
locals {
  target_clusters = {
    for role, c in var.target_components :
    role => local.state.foundation_libvirt_resources.foundation_topology.identity[c.service][c.component].cluster_name
  }
}
