
locals {
  _state_base = var.gitlab_terraform_state_base
}

locals {
  state = {
    platform_vault_downstream_frontend = data.terraform_remote_state.platform_vault_downstream_frontend.outputs
    foundation_libvirt_resources       = data.terraform_remote_state.foundation_libvirt_resources.outputs
  }
}

# The platform layer publishes the runtime, and a runtime object stays null on the other runtime.
locals {
  foundation_project_code  = local.state.foundation_libvirt_resources.foundation_vault_path.project_code
  vault_downstream_runtime = local.state.platform_vault_downstream_frontend.runtime
  is_runtime_talos         = local.vault_downstream_runtime.kubernetes_native
  vault_endpoint           = local.state.platform_vault_downstream_frontend.vault_endpoint
  foundation_kv_paths      = local.state.foundation_libvirt_resources.foundation_vault_path.kv_paths["vault-downstream"]["frontend"]
}
