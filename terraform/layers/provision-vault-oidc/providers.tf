
terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "5.13.0"
    }
  }
  backend "http" {
    address        = "https://gitlab.com/api/v4/projects/84608830/terraform/state/provision-vault-oidc"
    lock_address   = "https://gitlab.com/api/v4/projects/84608830/terraform/state/provision-vault-oidc/lock"
    unlock_address = "https://gitlab.com/api/v4/projects/84608830/terraform/state/provision-vault-oidc/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
    retry_wait_min = 5
  }
}

provider "vault" {
  alias        = "downstream"
  address      = local.downstream_vault.endpoint
  ca_cert_file = local.state.security_vault_downstream_tenants.downstream_vault_ca_cert_path

  # The JWT-SVID arrives through TERRAFORM_VAULT_AUTH_JWT from platform terraform and stays out of the state.
  auth_login_jwt {
    mount = local.terraform_operator.auth_mount
    role  = local.terraform_operator.role_name
  }
  skip_child_token = true
}
