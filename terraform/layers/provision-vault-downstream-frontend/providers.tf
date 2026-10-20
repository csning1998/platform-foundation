
terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "5.13.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "3.2.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.0.2"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0"
    }
  }
  backend "http" {
    address        = "https://gitlab.com/api/v4/projects/84608830/terraform/state/provision-vault-downstream-frontend"
    lock_address   = "https://gitlab.com/api/v4/projects/84608830/terraform/state/provision-vault-downstream-frontend/lock"
    unlock_address = "https://gitlab.com/api/v4/projects/84608830/terraform/state/provision-vault-downstream-frontend/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
    retry_wait_min = 5
  }
}

# The Bastion Vault holds the kubeconfig of the cluster and signs the listener certificate of the Downstream Vault.
# The .envrc of the layer routes VAULT_ADDR to the platform-foundation Vault Proxy, which overwrites the token of every request.
provider "vault" {
  alias            = "bastion"
  skip_child_token = true
}

provider "kubernetes" {
  host                   = local.vault_downstream_api_server_connection.host
  cluster_ca_certificate = local.vault_downstream_api_server_connection.ca_cert
  client_certificate     = local.vault_downstream_api_server_connection.client_certificate
  client_key             = local.vault_downstream_api_server_connection.client_key
}

provider "helm" {
  kubernetes = {
    host                   = local.vault_downstream_api_server_connection.host
    cluster_ca_certificate = local.vault_downstream_api_server_connection.ca_cert
    client_certificate     = local.vault_downstream_api_server_connection.client_certificate
    client_key             = local.vault_downstream_api_server_connection.client_key
  }
}
