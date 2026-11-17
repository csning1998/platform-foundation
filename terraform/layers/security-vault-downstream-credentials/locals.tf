
locals {
  _state_base = var.gitlab_terraform_state_base
}

locals {
  state = {
    security_vault_downstream_tenants = data.terraform_remote_state.security_vault_downstream_tenants.outputs
  }
}

# Provider prerequisites: Must be defined as root-level locals because provider blocks cannot reference module outputs.
locals {
  foundation_project_code = local.state.security_vault_downstream_tenants.foundation_vault_path.project_code
  downstream_kv_paths     = local.state.security_vault_downstream_tenants.foundation_vault_path.kv_paths

  # The addon prefix completes as addon-<name>, the form which platform-cilium-hubble grants to External Secrets Operator.
  kv_path_cilium_hubble_ui = "${local.downstream_kv_paths["cilium"]["hubble"].addon}-hubble-ui"

  downstream_vault = {
    endpoint     = local.state.security_vault_downstream_tenants.downstream_vault_endpoint
    ca_cert_path = local.state.security_vault_downstream_tenants.downstream_vault_ca_cert_path
  }
}

# The operator of the Downstream Vault logs in with the JWT-SVID of the SPIRE Parent.
locals {
  terraform_operator_subject = { service = "vault-downstream", component = "frontend" }
  terraform_operator         = local.state.security_vault_downstream_tenants.downstream_vault_operators[local.terraform_operator_subject.service][local.terraform_operator_subject.component]
}
