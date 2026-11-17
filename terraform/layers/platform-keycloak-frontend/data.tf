

data "terraform_remote_state" "foundation_libvirt_resources" {
  backend = "http"
  config  = { address = "${local._state_base}/foundation-libvirt-resources" }
}

data "terraform_remote_state" "security_vault_downstream_tenants" {
  backend = "http"
  config  = { address = "${local._state_base}/security-vault-downstream-tenants" }
}

data "terraform_remote_state" "security_vault_downstream_pki" {
  backend = "http"
  config  = { address = "${local._state_base}/security-vault-downstream-pki" }
}

data "terraform_remote_state" "platform_spire_parent" {
  backend = "http"
  config  = { address = "${local._state_base}/platform-spire-parent" }
}

data "terraform_remote_state" "provision_spire_child" {
  backend = "http"
  config  = { address = "${local._state_base}/provision-spire-child" }
}

data "terraform_remote_state" "provision_harbor_origin_frontend" {
  backend = "http"
  config  = { address = "${local._state_base}/provision-harbor-origin-frontend" }
}

# The Harbor robot pulls the charts from the private OCI project. The ephemeral read excludes the robot secret from the state.
ephemeral "vault_kv_secret_v2" "harbor_origin_robot" {
  provider = vault.downstream
  mount    = "secret"
  name     = local.downstream_kv_paths["harbor-origin"]["frontend"].robot
}

