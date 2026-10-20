
terraform {
  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = "5.7.0"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "5.13.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.6.3"
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
    address        = "https://gitlab.com/api/v4/projects/84608830/terraform/state/provision-keycloak-oidc"
    lock_address   = "https://gitlab.com/api/v4/projects/84608830/terraform/state/provision-keycloak-oidc/lock"
    unlock_address = "https://gitlab.com/api/v4/projects/84608830/terraform/state/provision-keycloak-oidc/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"
    retry_wait_min = 5
  }
}

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

provider "keycloak" {
  client_id           = "admin-cli"
  username            = local.keycloak_admin_user
  password            = local.keycloak_admin_password
  url                 = local.keycloak_frontend_url
  root_ca_certificate = base64decode(local.state.security_vault_downstream_pki.bastion_pki_chain_b64.content_b64)
  initial_login       = false
}

# The provider stays unconfigured on the VM runtime. The layer declares Kubernetes objects for the Talos runtime alone.
provider "kubernetes" {
  host                   = local.keycloak_api_server_connection.host
  cluster_ca_certificate = local.keycloak_api_server_connection.ca_cert
  client_certificate     = local.keycloak_api_server_connection.client_certificate
  client_key             = local.keycloak_api_server_connection.client_key
}

provider "helm" {
  kubernetes = {
    host                   = local.keycloak_api_server_connection.host
    cluster_ca_certificate = local.keycloak_api_server_connection.ca_cert
    client_certificate     = local.keycloak_api_server_connection.client_certificate
    client_key             = local.keycloak_api_server_connection.client_key
  }
}
