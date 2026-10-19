
terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "5.5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9.0"
    }
  }
  backend "http" {
    address        = "https://gitlab.com/api/v4/projects/84608830/terraform/state/security-pki"
    lock_address   = "https://gitlab.com/api/v4/projects/84608830/terraform/state/security-pki/lock"
    unlock_address = "https://gitlab.com/api/v4/projects/84608830/terraform/state/security-pki/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
    retry_wait_min = 5
  }
}

# The .envrc of the layer routes VAULT_ADDR to the platform-foundation Vault Proxy. The tenant ACL grants sign-intermediate on pki-intermediate-vault-downstream.
provider "vault" {
  alias            = "bastion"
  skip_child_token = true
}

# Downstream Provider: the administrator operator through its SPIRE Parent JWT-SVID, not the root token
# which security-vault-downstream-tenants uses for its own bootstrap operations.
provider "vault" {
  alias        = "downstream"
  address      = local.downstream_vault.endpoint
  ca_cert_file = local.state.platform_vault_downstream_frontend.vault_endpoint.ca_cert_path

  # The JWT-SVID arrives through TERRAFORM_VAULT_AUTH_JWT from platform terraform and stays out of the state.
  auth_login_jwt {
    mount = local.terraform_operator.auth_mount
    role  = local.terraform_operator.role_name
  }
  skip_child_token = true
}
