
data "terraform_remote_state" "foundation_libvirt_resources" {
  backend = "http"
  config  = { address = "${local._state_base_platform_foundation}/foundation-libvirt-resources" }
}

data "terraform_remote_state" "security_vault_downstream_tenants" {
  backend = "http"
  config  = { address = "${local._state_base_platform_foundation}/security-vault-downstream-tenants" }
}

data "terraform_remote_state" "platform_spire_parent" {
  backend = "http"
  config  = { address = "${local._state_base_platform_foundation}/platform-spire-parent-frontend" }
}

data "terraform_remote_state" "security_vault_downstream_pki" {
  backend = "http"
  config  = { address = "${local._state_base_platform_foundation}/security-pki" }
}
