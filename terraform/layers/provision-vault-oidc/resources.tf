
resource "vault_jwt_auth_backend" "keycloak" {
  provider              = vault.downstream
  description           = "OIDC Auth Backend for Keycloak"
  path                  = "oidc"
  type                  = "oidc"
  oidc_discovery_url    = local.oidc_discovery_url
  oidc_discovery_ca_pem = base64decode(local.state.security_vault_downstream_pki.bastion_pki_chain_b64.content_b64)
  oidc_client_id        = local.oidc_client_id
  oidc_client_secret    = local.oidc_client_secret

  tune {
    listing_visibility = "unauth"
    default_lease_ttl  = "1h"
    max_lease_ttl      = "24h"
  }
}

# Authenticates every Keycloak user and delegates authorization to Identity Group mappings evaluated from the roles claim,
# which contains the client roles of vault-infra granted to organization groups in provision-keycloak-oidc.
resource "vault_jwt_auth_backend_role" "keycloak_user" {
  provider             = vault.downstream
  backend              = vault_jwt_auth_backend.keycloak.path
  role_name            = "keycloak-user"
  token_policies       = ["default"]
  user_claim           = "preferred_username"
  groups_claim         = "roles"
  role_type            = "oidc"
  verbose_oidc_logging = true

  allowed_redirect_uris = local.state.provision_keycloak_oidc.keycloak_vault_redirect_uris
}

resource "vault_identity_group" "management_groups" {
  provider = vault.downstream
  for_each = local.state.security_vault_downstream_pki.downstream_pki_management_policies

  name     = "keycloak-${replace(each.key, "oidc-", "")}s"
  type     = "external"
  policies = [each.value]

  metadata = {
    source = "keycloak"
  }
}

resource "vault_identity_group_alias" "management_group_aliases" {
  provider = vault.downstream
  for_each = local.state.security_vault_downstream_pki.downstream_pki_management_policies

  # Maps external Keycloak group claims directly to canonical Vault identity group IDs.
  name           = replace(each.key, "oidc-", "")
  mount_accessor = vault_jwt_auth_backend.keycloak.accessor
  canonical_id   = vault_identity_group.management_groups[each.key].id
}
