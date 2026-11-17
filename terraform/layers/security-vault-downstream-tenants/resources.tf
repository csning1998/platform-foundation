
resource "vault_mount" "kv" {
  provider = vault.downstream

  path = "secret"
  type = "kv-v2"
}

# The SPIRE Parent precedes the Downstream Vault, hence every workstation operator logs in through this mount.
# The JWT-SVIDs of the SPIRE Parent contain the issuer which the server configuration of the SPIRE Parent sets.
resource "vault_jwt_auth_backend" "spire_parent" {
  provider = vault.downstream

  description = "JWT-SVID federation via the OIDC Discovery Provider of the SPIRE Parent"
  path        = local.state.platform_spire_parent.spire_oidc.auth_backend_path
  type        = "jwt"

  oidc_discovery_url    = local.state.platform_spire_parent.spire_oidc.discovery_url
  oidc_discovery_ca_pem = local.state.platform_spire_parent.spire_oidc.discovery_ca_pem
  bound_issuer          = local.state.platform_spire_parent.spire_oidc.discovery_url

  tune {
    listing_visibility = "unauth"
    default_lease_ttl  = "15m"
    max_lease_ttl      = "1h"
  }
}

resource "vault_policy" "tenant" {
  provider = vault.downstream
  for_each = local.tenants

  name   = each.key
  policy = jsonencode({ path = local.tenant_policy_paths[each.key] })
}

# The roles of Child tenants live on the Child mount, which provision-spire-child creates after the SPIRE Child exists.
resource "vault_jwt_auth_backend_role" "tenant" {
  provider = vault.downstream
  for_each = { for name, t in local.tenants : name => t if t.issuer == "parent" }

  backend         = local.jwt_auth.parent.mount_path
  role_name       = each.key
  role_type       = "jwt"
  bound_audiences = [local.jwt_auth.parent.audience]
  bound_subject   = each.value.spiffe_id
  user_claim      = "sub"
  token_policies  = [vault_policy.tenant[each.key].name]
  token_ttl       = 15 * 60
  token_max_ttl   = 60 * 60
}

# The administrator policy grants CRUD on tenant KV, PKI, OIDC, Kubernetes auth mounts, identity, and policies.
resource "vault_policy" "operator" {
  provider = vault.downstream

  name   = local.tenant_operator.role_name
  policy = jsonencode({ path = local.operator_policy_paths })
}

resource "vault_jwt_auth_backend_role" "operator" {
  provider = vault.downstream

  backend         = local.jwt_auth.parent.mount_path
  role_name       = local.tenant_operator.role_name
  role_type       = "jwt"
  bound_audiences = [local.jwt_auth.parent.audience]
  bound_subject   = "spiffe://${local.spiffe_trust_domain}${local.tenant_operator.spiffe_path}"
  user_claim      = "sub"

  token_policies = [vault_policy.operator.name]
  token_ttl      = 15 * 60
  token_max_ttl  = 60 * 60
}
