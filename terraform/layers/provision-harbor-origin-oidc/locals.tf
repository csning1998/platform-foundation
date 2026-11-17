
locals {
  _state_base = var.gitlab_terraform_state_base
}

locals {
  state = {
    security_vault_downstream_tenants = data.terraform_remote_state.security_vault_downstream_tenants.outputs
    platform_harbor_origin_frontend   = data.terraform_remote_state.platform_harbor_origin_frontend.outputs
  }

  downstream_vault_endpoint = "https://${local.state.security_vault_downstream_tenants.downstream_vault_service_vip}:443"
  downstream_kv_paths       = local.state.security_vault_downstream_tenants.foundation_vault_path.kv_paths
}

# The client identifier comes from the service catalog, and the issuer follows the realm which provision-keycloak-oidc declares.
locals {
  keycloak_realm          = "infra-company"
  keycloak_oidc_client_id = local.state.security_vault_downstream_tenants.foundation_pki.map["harbor-origin-frontend"].oidc_client.client_id
  keycloak_oidc_issuer    = "https://${local.state.security_vault_downstream_tenants.foundation_pki.map["keycloak-frontend"].dns_san[0]}/realms/${local.keycloak_realm}"
}

# The operator of this component logs in to the Downstream Vault with the JWT-SVID of the SPIRE Parent.
locals {
  terraform_operator_subject = { service = "harbor-origin", component = "frontend" }
  terraform_operator         = local.state.security_vault_downstream_tenants.downstream_vault_operators[local.terraform_operator_subject.service][local.terraform_operator_subject.component]
}
