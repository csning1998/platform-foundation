
terraform {
  required_providers {
    vault = {
      source                = "hashicorp/vault"
      version               = "5.13.0"
      configuration_aliases = [vault.issuing, vault.signing]
    }
    time = {
      source  = "hashicorp/time"
      version = "0.11.1"
    }
  }
}
