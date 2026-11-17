
data "terraform_remote_state" "foundation_libvirt_resources" {
  backend = "http"
  config  = { address = "${local._state_base}/foundation-libvirt-resources" }
}

# parent-group-governance publishes the Bastion facts of the tenant in the registry, in place of its Terraform state.
data "vault_generic_secret" "registry_bastion" {
  provider = vault.bastion
  path     = "registry/${local.foundation_project_code}/bastion"
}
