
terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "5.13.0"
    }
  }
}

# The policies exist already. On the Bastion Vault the policy broker of parent-group-governance writes them, since a
# tenant which writes both a policy and a role mints a token of any policy.
resource "vault_jwt_auth_backend_role" "this" {
  backend         = var.auth_backend_path
  role_name       = var.auth_role_name
  role_type       = "jwt"
  bound_audiences = [var.audience]
  bound_subject   = var.spiffe_id
  user_claim      = "sub"
  token_policies  = concat(["default"], var.token_policies)
  token_ttl       = var.token_ttl
  token_max_ttl   = var.token_max_ttl
}
