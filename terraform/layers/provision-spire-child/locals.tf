# GitLab HTTP backend base URL. Authentication credentials must be supplied via
# `TF_HTTP_USERNAME` and `TF_HTTP_PASSWORD` environment variables.
locals {
  _state_base_platform_foundation = "https://gitlab.com/api/v4/projects/84608830/terraform/state"
}

locals {
  state = {
    platform_spire_child              = data.terraform_remote_state.platform_spire_child.outputs
    platform_spire_parent             = data.terraform_remote_state.platform_spire_parent.outputs
    security_vault_downstream_tenants = data.terraform_remote_state.security_vault_downstream_tenants.outputs
    security_vault_downstream_pki     = data.terraform_remote_state.security_vault_downstream_pki.outputs
  }
}

locals {
  # The operator of the SPIRE Child logs in to the Downstream Vault with the JWT-SVID of the SPIRE Parent.
  terraform_operator_subject = { service = "spire", component = "child" }
  terraform_operator         = local.state.security_vault_downstream_tenants.downstream_vault_operators[local.terraform_operator_subject.service][local.terraform_operator_subject.component]
  spire_child_jwt_auth       = local.state.security_vault_downstream_tenants.spire_child_jwt_auth

  spire_child_topology     = local.state.platform_spire_child.foundation_topology
  spire_child_identity     = local.spire_child_topology.identity["spire"]["child"]
  spire_child_network      = local.spire_child_topology.network["spire"]["child"]
  spire_child_project_code = local.state.platform_spire_child.foundation_vault_path.project_code

  spire_parent_cluster_name = local.spire_child_topology.identity["spire"]["parent"].cluster_name
  spire_child_cluster_name  = local.spire_child_identity.cluster_name

  spire_child_kv_paths = {
    cluster         = local.state.platform_spire_child.foundation_vault_path.kv_paths["spire"]["child"].cluster_config
    parent_attestor = local.state.platform_spire_child.foundation_vault_path.kv_paths["spire"]["child"].parent_attestor
    registrar       = local.state.platform_spire_child.foundation_vault_path.kv_paths["spire"]["child"].registrar
  }
}

locals {
  spire_child_kubeconfig   = yamldecode(base64decode(ephemeral.vault_kv_secret_v2.spire_child.data["content_b64"]))
  spire_child_cluster_info = local.spire_child_kubeconfig.clusters[0].cluster
  spire_child_user_info    = local.spire_child_kubeconfig.users[0].user

  spire_child_api_server_connection = {
    host               = local.spire_child_cluster_info.server
    ca_cert            = base64decode(local.spire_child_cluster_info["certificate-authority-data"])
    client_certificate = base64decode(local.spire_child_user_info["client-certificate-data"])
    client_key         = base64decode(local.spire_child_user_info["client-key-data"])
  }

  # SPIRE parent interacts with the child Kubernetes API server via the control plane VIP.
  spire_child_api_server_vip_url = "https://${local.spire_child_network.vip}:6443"
}

# SPIRE parent and nested child share a unified SPIFFE trust domain across VM and container boundaries.
locals {
  spire_parent        = local.state.platform_spire_parent.spire_agent_bootstrap
  spiffe_trust_domain = local.spire_parent.trust_domain

  spiffe_workload_id = {
    # Downstream child SPIRE server workload identity.
    child_server = "spiffe://${local.spiffe_trust_domain}/${local.spire_child_project_code}/spire/child"
    # Upstream agent node alias grouping containerized agents under parent trust domain.
    upstream_agent_alias = "spiffe://${local.spiffe_trust_domain}/${local.spire_child_project_code}/spire/child/upstream-agent"
  }

  # Chart-standard namespace and service account names aligned with parent k8s_psat attestation allow-lists.
  spire_child_chart = {
    system_namespace        = "spire-system"
    server_namespace        = "spire-server"
    upstream_agent_sa       = "spire-agent-upstream"
    internal_server_sa      = "spire-internal-server"
    internal_server_service = "spire-internal-server"
    internal_server_pod     = "spire-internal-server-0"
    registrar_sa            = "spire-child-registrar"
    upstream_bundle_cm      = "spire-bundle-upstream"
    oidc_service_name       = "spiffe-oidc-discovery-provider"
    oidc_tls_secret         = "spiffe-oidc-discovery-provider-tls"
    parent_attestor_sa      = "spire-parent-attestor"
    parent_attestor_rbac    = "spire-parent-attestor"
    upstream_bundle_field   = "bundle.crt"
  }

  # OIDC discovery provider allocates the static VIP immediately following the control plane VIP.
  spire_child_oidc_vip = cidrhost(local.spire_child_network.cidr_block, local.state.platform_spire_child.foundation_network_global.network_baseline.host_vip_offset + 1)

  # The agents of the downstream VMs and of the operator workstation attest to the child server through this static VIP.
  spire_child_agent_vip  = cidrhost(local.spire_child_network.cidr_block, local.state.platform_spire_child.foundation_network_global.network_baseline.host_vip_offset + 2)
  spire_child_agent_port = 443
  spire_child_jwt_issuer = "https://${local.spire_child_oidc_vip}"
}

locals {
  ansible_config = {
    root_path         = abspath("${path.root}/../../../ansible")
    inventory_file    = "inventory-provision-spire-child.yaml"
    known_hosts_path  = local.state.platform_spire_child.foundation_ssh.known_hosts_paths[local.spire_parent_cluster_name]
    identity_key_path = local.state.platform_spire_child.foundation_ssh.identity_key_paths[local.spire_parent_cluster_name]
  }

  # The registration on the SPIRE Parent runs over SSH. workstation-agent.tf installs the agent of the workstation for the SPIRE Child.
  inventory_data = {
    all = {
      children = {
        spire_child_registration = {
          hosts = {
            (local.spire_parent.ssh_host) = {
              ansible_host = local.spire_parent.ssh_host
            }
          }
        }
      }
    }
  }

  # Execution variables contain non-sensitive coordinates. The runner retrieves secrets directly from the Downstream Vault.
  ansible_extra_vars = {
    operator_vault_ca_cert_path = local.state.security_vault_downstream_tenants.downstream_vault_ca_cert_path
    # The Downstream Vault takes no Proxy client certificate.
    operator_vault_client_cert                     = ""
    operator_vault_client_key                      = ""
    operator_vault_url                             = local.state.security_vault_downstream_tenants.downstream_vault_endpoint
    provision_spire_child_cluster_name             = local.spire_child_cluster_name
    provision_spire_child_kubeconfig_vault_path    = local.spire_child_kv_paths.parent_attestor
    provision_spire_child_upstream_agent_alias     = local.spiffe_workload_id.upstream_agent_alias
    provision_spire_child_server_spiffe_id         = local.spiffe_workload_id.child_server
    provision_spire_child_upstream_agent_namespace = local.spire_child_chart.system_namespace
    provision_spire_child_upstream_agent_sa        = local.spire_child_chart.upstream_agent_sa
    provision_spire_child_server_namespace         = local.spire_child_chart.server_namespace
    provision_spire_child_server_sa                = local.spire_child_chart.internal_server_sa
    provision_spire_child_operator_wrapper         = local.terraform_operator.wrapper_name
    provision_spire_child_operator_role            = local.terraform_operator.role_name
    provision_spire_child_operator_auth_mount      = local.terraform_operator.auth_mount
  }
}
