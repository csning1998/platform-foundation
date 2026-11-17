
data "terraform_remote_state" "platform_vault_downstream_frontend" {
  backend = "http"
  config  = { address = "${local._state_base}/platform-vault-downstream-frontend" }
}

data "terraform_remote_state" "security_vault_downstream_tenants" {
  backend = "http"
  config  = { address = "${local._state_base}/security-vault-downstream-tenants" }
}

data "terraform_remote_state" "security_vault_downstream_pki" {
  backend = "http"
  config  = { address = "${local._state_base}/security-vault-downstream-pki" }
}

data "terraform_remote_state" "provision_keycloak_oidc" {
  backend = "http"
  config  = { address = "${local._state_base}/provision-keycloak-oidc" }
}

# Read OIDC Client credentials from Vault (Created in provision-*)
data "vault_kv_secret_v2" "keycloak_vault_client" {
  provider = vault.downstream
  mount    = "secret"
  name     = "${local.state.security_vault_downstream_tenants.foundation_vault_path.project_code}/keycloak/oidc/clients/vault_frontend"
}
