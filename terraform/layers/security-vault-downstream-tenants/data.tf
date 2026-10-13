
data "terraform_remote_state" "foundation_libvirt_resources" {
  backend = "http"
  config  = { address = "${local._state_base_platform_foundation}/foundation-libvirt-resources" }
}

data "terraform_remote_state" "platform_vault_downstream_frontend" {
  backend = "http"
  config  = { address = "${local._state_base_platform_foundation}/platform-vault-frontend" }
}

data "terraform_remote_state" "platform_spire_parent" {
  backend = "http"
  config  = { address = "${local._state_base_platform_foundation}/platform-spire-parent-frontend" }
}

data "terraform_remote_state" "provision_spire_parent" {
  backend = "http"
  config  = { address = "${local._state_base_platform_foundation}/provision-spire-parent-frontend" }
}

ephemeral "vault_kv_secret_v2" "downstream_init" {
  provider = vault.bastion

  mount = "secret"
  name  = local.downstream_vault_config.init_kv_path
}
