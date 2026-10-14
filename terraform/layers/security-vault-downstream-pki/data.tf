
data "terraform_remote_state" "platform_vault_downstream_frontend" {
  backend = "http"
  config  = { address = "${local._state_base_platform_foundation}/platform-vault-frontend" }
}

data "terraform_remote_state" "security_vault_downstream_tenants" {
  backend = "http"
  config  = { address = "${local._state_base_platform_foundation}/security-vault-downstream-tenants" }
}

data "terraform_remote_state" "foundation_libvirt_resources" {
  backend = "http"
  config  = { address = "${local._state_base_platform_foundation}/foundation-libvirt-resources" }
}

# parent-group-governance publishes the Bastion facts of the tenant in the registry, in place of its Terraform state.
data "vault_generic_secret" "registry_bastion" {
  provider = vault.bastion
  path     = "registry/${local.foundation_project_code}/bastion"
}

# The SPIRE trust domains are the stage domains below which every catalog service of every owner is named.
data "vault_generic_secret" "registry_platform_trust" {
  provider = vault.bastion
  path     = "registry/platform/trust"
}
