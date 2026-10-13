
terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "5.5.0"
    }
  }
  backend "http" {
    address        = "https://gitlab.com/api/v4/projects/84608830/terraform/state/security-vault-downstream-tenants"
    lock_address   = "https://gitlab.com/api/v4/projects/84608830/terraform/state/security-vault-downstream-tenants/lock"
    unlock_address = "https://gitlab.com/api/v4/projects/84608830/terraform/state/security-vault-downstream-tenants/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
    retry_wait_min = 5
  }
}

# The .envrc of the layer routes VAULT_ADDR to the platform-foundation Vault Proxy, whose token reads the init leaf alone.
provider "vault" {
  alias            = "bastion"
  skip_child_token = true
}

# Downstream Vault provider uses ephemeral bootstrap root token to configure initial JWT auth and tenant policies.
provider "vault" {
  alias            = "downstream"
  address          = local.downstream_vault_config.endpoint
  ca_cert_file     = local.downstream_vault_config.ca_cert_path
  token            = ephemeral.vault_kv_secret_v2.downstream_init.data["prod_vault_root_token"]
  skip_child_token = true
}
