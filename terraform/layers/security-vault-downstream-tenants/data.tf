
data "terraform_remote_state" "foundation_libvirt_resources" {
  backend = "http"
  config  = { address = "${local._state_base}/foundation-libvirt-resources" }
}

data "terraform_remote_state" "platform_vault_downstream_frontend" {
  backend = "http"
  config  = { address = "${local._state_base}/platform-vault-downstream-frontend" }
}

data "terraform_remote_state" "platform_spire_parent" {
  backend = "http"
  config  = { address = "${local._state_base}/platform-spire-parent" }
}

data "terraform_remote_state" "provision_spire_parent" {
  backend = "http"
  config  = { address = "${local._state_base}/provision-spire-parent" }
}

ephemeral "vault_kv_secret_v2" "downstream_init" {
  provider = vault.bastion

  mount = "secret"
  name  = local.downstream_vault_config.init_kv_path
}
