
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
    helm = {
      source  = "hashicorp/helm"
      version = "3.0.2"
    }
  }
  backend "http" {
    address        = "https://gitlab.com/api/v4/projects/84608830/terraform/state/platform-cilium-hubble"
    lock_address   = "https://gitlab.com/api/v4/projects/84608830/terraform/state/platform-cilium-hubble/lock"
    unlock_address = "https://gitlab.com/api/v4/projects/84608830/terraform/state/platform-cilium-hubble/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
    retry_wait_min = 5
  }
}

provider "libvirt" {
  uri = "qemu:///system?socket=/var/run/libvirt/virtqemud-sock"
}

# Authenticated as the local Terraform operator of this component through the SPIRE Parent JWT-SVID.
provider "vault" {
  alias        = "downstream"
  address      = local.downstream_vault_endpoint
  ca_cert_file = local.vault_pki_cert_path

  # The JWT-SVID arrives through TERRAFORM_VAULT_AUTH_JWT from platform terraform and stays out of the state.
  auth_login_jwt {
    mount = local.terraform_operator.auth_mount
    role  = local.terraform_operator.role_name
  }
  skip_child_token = true
}

# The OCI registry client of the provider lacks a CA option. SSL_CERT_DIR of the repository .envrc supplies the Downstream PKI trust bundle.
provider "helm" {
  registries = [
    {
      url      = "oci://${local.harbor_registry_mirror.host}"
      username = ephemeral.vault_kv_secret_v2.harbor_origin_robot.data["username_puller"]
      password = ephemeral.vault_kv_secret_v2.harbor_origin_robot.data["password_puller"]
    }
  ]
}
