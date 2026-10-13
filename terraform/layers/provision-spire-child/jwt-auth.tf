
# The Downstream Vault trusts the JWT-SVIDs of Child workloads through this backend. Vault fetches the discovery document at
# creation, hence the backend follows the OIDC discovery provider of the chart.
resource "vault_jwt_auth_backend" "spire_child" {
  provider   = vault.downstream
  depends_on = [helm_release.spire_nested]

  description = "Tenant workload JWT-SVID federation via the OIDC Discovery Provider of the SPIRE Child"
  path        = local.spire_child_jwt_auth.mount_path
  type        = "jwt"

  oidc_discovery_url    = local.spire_child_jwt_issuer
  oidc_discovery_ca_pem = base64decode(local.state.security_vault_downstream_pki.bastion_pki_chain_b64.content_b64)
  bound_issuer          = local.spire_child_jwt_issuer

  tune {
    listing_visibility = "unauth"
    default_lease_ttl  = "15m"
    max_lease_ttl      = "1h"
  }
}

# security-vault-downstream-tenants declares the policy of every Child tenant, and the operator assigns only those names.
resource "vault_jwt_auth_backend_role" "tenant" {
  provider = vault.downstream
  for_each = local.spire_child_jwt_auth.tenants

  backend         = vault_jwt_auth_backend.spire_child.path
  role_name       = each.key
  role_type       = "jwt"
  bound_audiences = [local.spire_child_jwt_auth.audience]
  bound_subject   = each.value.spiffe_id
  user_claim      = "sub"
  token_policies  = [each.value.policy_name]
  token_ttl       = 15 * 60
  token_max_ttl   = 60 * 60
}

# security-vault-downstream-tenants declares the policy of every operator of the components deployed after the SPIRE Child.
resource "vault_jwt_auth_backend_role" "operator" {
  provider = vault.downstream
  for_each = local.spire_child_jwt_auth.operators

  backend         = vault_jwt_auth_backend.spire_child.path
  role_name       = each.key
  role_type       = "jwt"
  bound_audiences = [local.spire_child_jwt_auth.audience]
  bound_subject   = each.value.spiffe_id
  user_claim      = "sub"
  token_policies  = [each.value.policy_name]
  token_ttl       = 15 * 60
  token_max_ttl   = 60 * 60
}
