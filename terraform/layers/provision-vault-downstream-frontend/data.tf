
# Declarations which both runtimes share. runtime-talos.tf contains the declarations of the Talos runtime, and the VM runtime
# initializes and unseals the Downstream Vault through the Ansible play of platform-vault-downstream-frontend.
data "terraform_remote_state" "platform_vault_downstream_frontend" {
  backend = "http"
  config  = { address = "${local._state_base}/platform-vault-downstream-frontend" }
}

data "terraform_remote_state" "foundation_libvirt_resources" {
  backend = "http"
  config  = { address = "${local._state_base}/foundation-libvirt-resources" }
}
