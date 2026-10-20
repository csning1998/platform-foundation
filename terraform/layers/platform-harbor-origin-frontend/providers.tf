
terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "5.13.0"
    }
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.7"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.6.1"
    }
  }
  backend "http" {
    address        = "https://gitlab.com/api/v4/projects/84608830/terraform/state/platform-harbor-origin-frontend"
    lock_address   = "https://gitlab.com/api/v4/projects/84608830/terraform/state/platform-harbor-origin-frontend/lock"
    unlock_address = "https://gitlab.com/api/v4/projects/84608830/terraform/state/platform-harbor-origin-frontend/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
    retry_wait_min = 5
  }
}

provider "libvirt" {
  uri = "qemu:///system?socket=/var/run/libvirt/virtqemud-sock"
}

# Authenticated as the local Terraform operator of this component through SPIRE JWT-SVID.
provider "vault" {
  alias        = "downstream"
  address      = local.state.security_vault_downstream_tenants.downstream_vault_endpoint
  ca_cert_file = local.state.security_vault_downstream_tenants.downstream_vault_ca_cert_path

  # The JWT-SVID arrives through TERRAFORM_VAULT_AUTH_JWT from platform terraform and stays out of the state.
  auth_login_jwt {
    mount = local.terraform_operator.auth_mount
    role  = local.terraform_operator.role_name
  }
  skip_child_token = true
}
