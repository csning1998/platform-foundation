
# The layer does not declare a Vault provider. The plays write the join tokens to the Bastion KV through the platform-foundation Vault Proxy.
terraform {
  required_providers {
    ansible = {
      source  = "ansible/ansible"
      version = "~> 1.5.0"
    }
  }
  backend "http" {
    lock_method    = "POST"
    unlock_method  = "DELETE"
    retry_wait_min = 5
  }
}
