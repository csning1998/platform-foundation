
# Installs the second SPIRE Agent of the operator workstation, which attests to the SPIRE Child, and registers on the Child
# the operators of the components deployed after the SPIRE Child together with their JWT-SVID wrappers.
module "workstation_child_agent" {
  source = "../../modules/kvm-provisioning/configure/ansible-runner"

  depends_on = [
    helm_release.spire_nested,
    vault_kv_secret_v2.registrar,
    kubernetes_role_binding_v1.registrar,
    vault_jwt_auth_backend_role.operator,
  ]

  status_trigger = local.workstation_agent_status_trigger
  ansible_config = local.workstation_agent_ansible_config
  inventory_data = local.workstation_agent_inventory_data
  extra_vars     = local.workstation_agent_extra_vars
  playbook_paths = [
    "${local.ansible_config.root_path}/playbooks/playbook_host_terraform_operator.yaml"
  ]
  ansible_tags = ["spire_agent_child", "terraform_operator_identity", "terraform_operator_verify"]
}

locals {
  # The workstation agents register under this cluster name on both SPIRE servers, as provision-spire-parent declares.
  workstation_cluster_name = "host-terraform-operator"

  workstation_agent_ansible_config = {
    root_path      = local.ansible_config.root_path
    inventory_file = "inventory-provision-spire-child-workstation-agent.yaml"
  }

  workstation_agent_inventory_data = {
    all = {
      hosts = {
        "${local.workstation_cluster_name}-workstation" = {
          ansible_connection = "local"
          node_role          = "host_terraform_operator"
        }
      }
      vars = {
        ansible_python_interpreter = "/usr/bin/python3"
      }
    }
  }

  # The join token and the registrar kubeconfig of the SPIRE Child live in the Downstream KV.
  workstation_agent_extra_vars = {
    spire_cluster_name             = local.workstation_cluster_name
    spire_trust_domain             = local.spiffe_trust_domain
    spire_child_agent_address      = local.spire_child_agent_vip
    spire_child_agent_port         = tostring(local.spire_child_agent_port)
    spire_child_kubeconfig_kv_path = local.spire_child_kv_paths.registrar
    spire_child_join_token_kv_path = local.state.platform_spire_child.foundation_vault_path.kv_paths["spire"]["child"].join_token
    spire_jwt_issuer               = local.spire_child_jwt_issuer

    # The operator identities attest through the agent of the Child and request the audience which the Child mount binds.
    utils_terraform_operator_identity_spire_instance           = "child"
    utils_terraform_operator_identity_spire_server_kind        = "child"
    utils_terraform_operator_identity_child_kubeconfig_kv_path = local.spire_child_kv_paths.registrar
    utils_terraform_operator_identity_jwt_audience             = local.spire_child_jwt_auth.audience
    utils_terraform_operator_identity_names                    = jsonencode(sort(keys(local.spire_child_jwt_auth.operators)))
    utils_terraform_operator_identity_spiffe_paths             = jsonencode({ for name, operator in local.spire_child_jwt_auth.operators : name => operator.spiffe_path })

    operator_vault_url          = local.state.security_vault_downstream_tenants.downstream_vault_endpoint
    operator_vault_ca_cert_path = local.state.security_vault_downstream_tenants.downstream_vault_ca_cert_path
    # The Downstream Vault takes no Proxy client certificate.
    operator_vault_client_cert = ""
    operator_vault_client_key  = ""
    operator_vault_wrapper     = local.terraform_operator.wrapper_name
    operator_vault_role        = local.terraform_operator.role_name
    operator_vault_auth_mount  = local.terraform_operator.auth_mount
  }

  # A change of the agent endpoint, the registrar kubeconfig, or the operator list reruns the installation.
  workstation_agent_status_trigger = {
    agent_endpoint       = "${local.spire_child_agent_vip}:${local.spire_child_agent_port}"
    registrar_kv_version = vault_kv_secret_v2.registrar.metadata["version"]
    trust_domain         = local.spiffe_trust_domain
    operators            = local.spire_child_jwt_auth.operators
  }
}
