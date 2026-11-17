
# The OIDC part of Harbor Origin follows Keycloak. The client credentials come from the Downstream Vault,
# where provision-keycloak-oidc writes the credentials.
data "terraform_remote_state" "security_vault_downstream_tenants" {
  backend = "http"
  config  = { address = "${local._state_base}/security-vault-downstream-tenants" }
}

data "terraform_remote_state" "platform_harbor_origin_frontend" {
  backend = "http"
  config  = { address = "${local._state_base}/platform-harbor-origin-frontend" }
}

ephemeral "vault_kv_secret_v2" "harbor_origin" {
  provider = vault.downstream
  mount    = "secret"
  name     = local.downstream_kv_paths["harbor-origin"]["frontend"].app
}

# The client secret reaches harbor_config_auth as a write-only argument and is excluded from the state.
ephemeral "vault_kv_secret_v2" "keycloak_oidc_client" {
  provider = vault.downstream
  mount    = "secret"
  name     = "${local.state.security_vault_downstream_tenants.foundation_vault_path.project_code}/keycloak/oidc/clients/harbor-origin-frontend"
}
