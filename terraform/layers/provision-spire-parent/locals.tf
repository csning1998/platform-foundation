
# GitLab HTTP backend base URL. Authentication credentials must be supplied via
# `TF_HTTP_USERNAME` and `TF_HTTP_PASSWORD` environment variables.
locals {
  _state_base_platform_foundation = "https://gitlab.com/api/v4/projects/84608830/terraform/state"
}

locals {
  state = {
    foundation_libvirt_resources = data.terraform_remote_state.foundation_libvirt_resources.outputs
    platform_spire_parent        = data.terraform_remote_state.platform_spire_parent.outputs
  }
}

locals {
  foundation_project_code = local.state.foundation_libvirt_resources.foundation_vault_path.project_code
  spire_parent_identity   = local.state.foundation_libvirt_resources.foundation_topology.identity
  foundation_kv_paths     = local.state.foundation_libvirt_resources.foundation_vault_path.kv_paths

  # The workstation agents register under this cluster name on both SPIRE servers.
  workstation_cluster_name = "host-terraform-operator"
}

locals {
  # Operators of the components deployed before the SPIRE Child, keyed as in output terraform_operator.
  # security-vault-downstream-tenants declares the operators of the components deployed after the SPIRE Child.
  # The vault-downstream operator administers the Downstream Vault, and the platform-foundation Vault Proxy carries every Bastion change.
  _spire_parent_operator_targets = {
    "spire-child"      = { owner = local.foundation_project_code, service = "spire", component = "child" }
    "vault-downstream" = { owner = local.foundation_project_code, service = "vault-downstream", component = "frontend" }
  }

  spire_parent_operators = module.spire_parent_operator_identity.operator_identity.operators
}

locals {
  ansible_config = {
    root_path      = abspath("${path.root}/../../../ansible")
    inventory_file = "inventory-provision-spire-parent-frontend-operator.yaml"
  }

  inventory_data = {
    all = {
      hosts = {
        "host-terraform-operator-workstation" = {
          ansible_connection = "local"
          node_role          = "host_terraform_operator"
        }
      }
      vars = {
        ansible_python_interpreter = "/usr/bin/python3"
        spire_cluster_name         = local.workstation_cluster_name
        spire_trust_domain         = local.state.platform_spire_parent.spire_agent_bootstrap.trust_domain
        spire_parent_node_ip       = local.state.platform_spire_parent.spire_agent_bootstrap.node_ip
        spire_parent_ssh_host      = local.state.platform_spire_parent.spire_agent_bootstrap.ssh_host
        spire_server_port          = tostring(local.state.platform_spire_parent.spire_agent_bootstrap.server_port)
      }
    }
  }

  # The plays take the Vault address, the CA path, and the client certificate from the platform-foundation Vault Proxy environment.
  ansible_extra_vars = {
    operator_vault_use_ambient_token               = true
    spire_jwt_issuer                               = local.state.platform_spire_parent.spire_oidc.discovery_url
    spire_parent_join_token_kv_path                = local.foundation_kv_paths["spire"]["parent"].join_token
    spire_child_join_token_kv_path                 = local.foundation_kv_paths["spire"]["child"].join_token
    utils_terraform_operator_identity_names        = jsonencode(sort([for operator in local.spire_parent_operators : operator.role_name]))
    utils_terraform_operator_identity_spiffe_paths = jsonencode({ for operator in local.spire_parent_operators : operator.role_name => operator.spiffe_path })
  }
}
