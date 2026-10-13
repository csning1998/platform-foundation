
# GitLab HTTP backend base URL. Authentication credentials must be supplied via
# `TF_HTTP_USERNAME` and `TF_HTTP_PASSWORD` environment variables.
locals {
  _state_base_platform_foundation = "https://gitlab.com/api/v4/projects/84608830/terraform/state"
}

locals {
  state = {
    foundation_libvirt_resources       = data.terraform_remote_state.foundation_libvirt_resources.outputs
    platform_vault_downstream_frontend = data.terraform_remote_state.platform_vault_downstream_frontend.outputs
    platform_spire_parent              = data.terraform_remote_state.platform_spire_parent.outputs
    provision_spire_parent             = data.terraform_remote_state.provision_spire_parent.outputs
  }
}

locals {
  foundation_project_code = local.state.foundation_libvirt_resources.foundation_vault_path.project_code
  foundation_kv_paths     = local.state.foundation_libvirt_resources.foundation_vault_path.kv_paths
  spiffe_trust_domain     = local.state.platform_spire_parent.spire_agent_bootstrap.trust_domain

  downstream_vault_config = {
    # provision-vault-downstream-frontend writes the root token of the initialization to this KV path of the Bastion Vault.
    init_kv_path   = local.state.foundation_libvirt_resources.foundation_vault_path.kv_paths["vault-downstream"]["frontend"].init
    endpoint       = local.state.platform_vault_downstream_frontend.vault_endpoint.address
    ca_cert_path   = local.state.platform_vault_downstream_frontend.vault_endpoint.ca_cert_path
    pki_mount_path = local.state.platform_vault_downstream_frontend.pki_identity.intermediate_mount_path
  }

  # The SPIRE Parent mount keeps the audience vault, which the JWT-SVID wrappers of the workstation request.
  jwt_auth = {
    parent = {
      mount_path = vault_jwt_auth_backend.spire_parent.path
      audience   = "vault"
    }
  }

  # Operators of the components deployed after the SPIRE Child, keyed as in output downstream_vault_config_operators.
  # provision-spire-child registers these operators on the Child and creates their roles on the Child mount.
  _spire_child_operator_targets = {
    "cilium"        = { owner = local.foundation_project_code, service = "cilium", component = "hubble" }
    "harbor-origin" = { owner = local.foundation_project_code, service = "harbor-origin", component = "frontend" }
    "keycloak"      = { owner = local.foundation_project_code, service = "keycloak", component = "frontend" }
  }

  # Each operator binds its exact SPIFFE ID. A glob over terraform-operator/* would let every component assume the administrator.
  # provision-spire-parent declares the operators of the components deployed before the SPIRE Child.
  terraform_operators = merge(
    local.state.provision_spire_parent.terraform_operator,
    module.spire_child_operator_identity.operator_identity.operators,
  )

  # The workstation agents register under this cluster name on both SPIRE servers, as provision-spire-parent declares.
  workstation_cluster_name = "host-terraform-operator"
  tenant_operator          = local.terraform_operators["vault-downstream"]
  component_operators      = { for key, operator in local.terraform_operators : key => operator if key != "vault-downstream" }
}

# Tenant names, SPIFFE IDs, KV paths, and PKI roles derive from the owner code. No input repeats the project code.
locals {
  tenants = {
    for key, t in var.tenants : "${coalesce(t.owner, local.foundation_project_code)}-${key}" => {
      issuer = t.issuer
      spiffe_id = (t.workload != null
        ? "spiffe://${local.spiffe_trust_domain}/${coalesce(t.owner, local.foundation_project_code)}/${t.workload.service}/${t.workload.component}"
        : "spiffe://${local.spiffe_trust_domain}/ns/${t.kubernetes.namespace}/sa/${t.kubernetes.service_account}"
      )
      kv_paths      = [for p in t.kv_paths : "${coalesce(t.owner, local.foundation_project_code)}/${p}"]
      kv_read_paths = [for p in t.kv_read_paths : "${coalesce(t.owner, local.foundation_project_code)}/${p}"]
      pki_roles     = [for r in t.pki_roles : "${coalesce(t.owner, local.foundation_project_code)}-${r}"]
    }
  }
}
