
# Delegates Harbor user authentication to Keycloak OIDC with automated on-boarding.
resource "harbor_config_auth" "main" {
  auth_mode                     = "oidc_auth"
  primary_auth_mode             = true
  oidc_name                     = "Keycloak"
  oidc_endpoint                 = local.keycloak_oidc_issuer
  oidc_client_id                = local.keycloak_oidc_client_id
  oidc_client_secret_wo         = ephemeral.vault_kv_secret_v2.keycloak_oidc_client.data["client_secret"]
  oidc_client_secret_wo_version = 1
  oidc_scope                    = "openid,profile,email"
  oidc_verify_cert              = true
  oidc_auto_onboard             = true
  oidc_user_claim               = "preferred_username"
  oidc_groups_claim             = "roles"

  # The roles claim contains the client roles of Harbor, and the client role admin grants system administrator privileges.
  oidc_admin_group = "admin"
}

resource "harbor_group" "infra_admins" {
  group_name = "admin"
  group_type = 3
}
