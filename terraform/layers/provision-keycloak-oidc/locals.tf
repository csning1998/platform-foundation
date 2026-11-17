
locals {
  _state_base = var.gitlab_terraform_state_base
}

locals {
  state = {
    foundation_libvirt_resources      = data.terraform_remote_state.foundation_libvirt_resources.outputs
    security_vault_downstream_tenants = data.terraform_remote_state.security_vault_downstream_tenants.outputs
    security_vault_downstream_pki     = data.terraform_remote_state.security_vault_downstream_pki.outputs
    platform_keycloak_frontend        = data.terraform_remote_state.platform_keycloak_frontend.outputs
  }

  downstream_kv_paths        = local.state.security_vault_downstream_tenants.foundation_vault_path.kv_paths
  terraform_operator_subject = { service = "keycloak", component = "frontend" }
  terraform_operator         = local.state.security_vault_downstream_tenants.downstream_vault_operators[local.terraform_operator_subject.service][local.terraform_operator_subject.component]
}

locals {
  keycloak_fqdn = {
    keycloak_frontend = local.state.security_vault_downstream_tenants.foundation_pki.map["keycloak-frontend"].dns_san[0]
    vault_frontend    = local.state.security_vault_downstream_tenants.foundation_pki.map["vault-downstream-frontend"].dns_san[0]
  }

  keycloak_frontend_url = "https://${local.keycloak_fqdn.keycloak_frontend}"
  vault_frontend_url    = "https://${local.keycloak_fqdn.vault_frontend}"

  keycloak_admin_user     = ephemeral.vault_kv_secret_v2.keycloak_admin.data["keycloak_admin_user"]
  keycloak_admin_password = ephemeral.vault_kv_secret_v2.keycloak_admin.data["keycloak_admin_password"]

  keycloak_realm_id = "infra-company"

  keycloak_all_group_ids = merge(
    { for k, v in keycloak_group.root_groups : k => v.id },
    { for k, v in keycloak_group.subgroups : k => v.id }
  )
}

locals {
  vault_redirect_uris = [
    "${local.vault_frontend_url}/ui/vault/auth/oidc/oidc/callback",
    "${local.vault_frontend_url}/ui/vault/auth/oidc/callback",
    "${local.vault_frontend_url}/vault/oidc/callback",
    "http://localhost:8250/oidc/callback"
  ]

  # Downstream OIDC clients derived from global_pki_map: declaring oidc_client on a
  # component in service_catalog is sufficient to onboard a new consumer here.
  downstream_oidc_clients_resolved = {
    for k, v in local.state.security_vault_downstream_tenants.foundation_pki.map : k => {
      client_id           = v.oidc_client.client_id
      name                = v.oidc_client.name
      valid_redirect_uris = ["https://${v.dns_san[0]}${v.oidc_client.redirect_path}"]
      web_origin          = "https://${v.dns_san[0]}"
    }
    if v.oidc_client != null
  }

  # Keeps vault_frontend static because the client carries the audience mapper and multiple redirect URIs, unlike single-callback services.
  oidc_clients_all = merge({
    vault_frontend = {
      client_id           = "vault-infra"
      name                = "Vault Infrastructure"
      valid_redirect_uris = local.vault_redirect_uris
      web_origin          = local.vault_frontend_url
    }
  }, local.downstream_oidc_clients_resolved)
}

locals {
  is_runtime_talos          = local.state.platform_keycloak_frontend.runtime.kubernetes_native
  keycloak_external_secrets = local.state.platform_keycloak_frontend.talos_cluster.external_secrets
  keycloak_cluster_issuer   = local.state.platform_keycloak_frontend.talos_cluster.cluster_issuer
  keycloak_cluster_name     = local.state.foundation_libvirt_resources.foundation_topology.identity["keycloak"]["frontend"].cluster_name
  keycloak_cluster_vip      = local.state.foundation_libvirt_resources.foundation_topology.infrastructure[local.keycloak_cluster_name].lb_config.vip

  downstream_vault = {
    address = local.state.security_vault_downstream_tenants.downstream_vault_endpoint
    ca_cert = file(local.state.security_vault_downstream_tenants.downstream_vault_ca_cert_path)
  }

  keycloak_kubeconfig = local.is_runtime_talos ? yamldecode(base64decode(ephemeral.vault_kv_secret_v2.keycloak_cluster[0].data["content_b64"])) : null

  keycloak_api_server_connection = local.is_runtime_talos ? {
    host               = local.keycloak_kubeconfig.clusters[0].cluster.server
    ca_cert            = base64decode(local.keycloak_kubeconfig.clusters[0].cluster["certificate-authority-data"])
    client_certificate = base64decode(local.keycloak_kubeconfig.users[0].user["client-certificate-data"])
    client_key         = base64decode(local.keycloak_kubeconfig.users[0].user["client-key-data"])
    } : {
    host               = null
    ca_cert            = null
    client_certificate = null
    client_key         = null
  }

  # The token reviewer authenticates to the API server on its own, with the VIP of the cluster and its root CA.
  keycloak_api_server_callback = local.is_runtime_talos ? {
    host    = "https://${local.keycloak_cluster_vip}:6443"
    ca_cert = data.kubernetes_config_map_v1.root_ca[0].data["ca.crt"]
  } : null
}
