
terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "5.13.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.6.3"
    }
  }
  backend "http" {
    address        = "https://gitlab.com/api/v4/projects/84608830/terraform/state/security-vault-downstream-credentials"
    lock_address   = "https://gitlab.com/api/v4/projects/84608830/terraform/state/security-vault-downstream-credentials/lock"
    unlock_address = "https://gitlab.com/api/v4/projects/84608830/terraform/state/security-vault-downstream-credentials/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
    retry_wait_min = 5
  }
}

provider "vault" {
  alias        = "downstream"
  address      = local.downstream_vault.endpoint
  ca_cert_file = local.downstream_vault.ca_cert_path

  # The JWT-SVID arrives through TERRAFORM_VAULT_AUTH_JWT from platform terraform and stays out of the state.
  auth_login_jwt {
    mount = local.terraform_operator.auth_mount
    role  = local.terraform_operator.role_name
  }
  skip_child_token = true
}
