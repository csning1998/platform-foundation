
terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.7"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "5.13.0"
    }
  }
  backend "http" {
    address        = "https://gitlab.com/api/v4/projects/84608830/terraform/state/platform-spire-parent-frontend"
    lock_address   = "https://gitlab.com/api/v4/projects/84608830/terraform/state/platform-spire-parent-frontend/lock"
    unlock_address = "https://gitlab.com/api/v4/projects/84608830/terraform/state/platform-spire-parent-frontend/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
    retry_wait_min = 5
  }
}

provider "libvirt" {
  uri = "qemu:///system?socket=/var/run/libvirt/virtqemud-sock"
}

# The .envrc of the layer routes VAULT_ADDR to the platform-foundation Vault Proxy, hence the layer holds no Bastion credential.
# The Proxy overwrites the token of every request, hence the provider skips the child token.
provider "vault" {
  skip_child_token = true
}
