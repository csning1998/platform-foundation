
# Declarations of the Talos runtime alone. Each resource and module carries count = local.is_runtime_talos ? 1 : 0.
locals {
  # The Downstream Vault precedes Harbor Origin, hence the charts come from the upstream registries.
  vault_downstream_chart_repository = {
    cilium       = "oci://quay.io/cilium/charts"
    cert_manager = "oci://quay.io/jetstack/charts"
  }

  # Each node takes the address at its position in the sorted node keys from the foundation derivation.
  bastion_network_nodes = {
    for idx, key in sort(keys(var.node_config)) : key => {
      (local.state.foundation_libvirt_resources.foundation_bastion_network.network_name) = local.state.foundation_libvirt_resources.foundation_bastion_network.addresses[local.vault_downstream_cluster_name][idx]
    }
  }

  vault_workload = {
    namespace       = "vault"
    service_account = "vault"
  }

  # The Service names of the chart live below <namespace>.svc.cluster.local, and the role admits each subdomain.
  vault_service_domain = "${local.vault_workload.namespace}.svc.cluster.local"

  transit_unseal_consumer = local.registry_bastion.transit_unseal.consumers["${local.foundation_project_code}-vault-downstream"]

  # The transit token works only from the addresses of the Vault nodes on vault-bastion-publish.
  transit_unseal_source_cidrs = [
    for address in local.state.foundation_libvirt_resources.foundation_bastion_network.addresses[local.vault_downstream_cluster_name] : "${split("/", address)[0]}/32"
  ]
}

resource "terraform_data" "talos_inputs_validation" {
  count = local.is_runtime_talos ? 1 : 0
  input = local.vault_downstream_cluster_runtime

  lifecycle {
    precondition {
      condition     = var.talos_config != null && var.helm_chart_version != null && length(var.node_config) > 0
      error_message = "The Talos runtime of vault-downstream requires talos_config, helm_chart_version, and node_config."
    }
  }
}

module "helm_chart_cilium" {
  count  = local.is_runtime_talos ? 1 : 0
  source = "../../modules/kubernetes-addons/helm-chart-cilium"

  helm_config = {
    chart_repository   = local.vault_downstream_chart_repository.cilium
    version            = var.helm_chart_version.cilium
    kubernetes_version = var.talos_config.kubernetes_version
  }
  cilium_config = {
    kubeprism_port = var.talos_config.kubeprism_port
    node_count     = length(var.node_config)
    mtu            = local.state.foundation_libvirt_resources.foundation_network_global.network_baseline.global_mtu
  }
}

# cert-manager issues the Vault listener certificate from pki-leaf-platform, since the Downstream Vault cannot sign its own listener.
# The Kubernetes auth mount lives in the owned scope of the tenant, which admits the issuer policy of pki-leaf-platform.
module "vault_kubernetes_auth_talos" {
  count     = local.is_runtime_talos ? 1 : 0
  source    = "../../modules/vault-provisioning/vault-kubernetes-auth"
  providers = { vault = vault.bastion }

  cluster_name = local.vault_downstream_cluster_name
  pki_config = {
    mount_path           = local.bastion_pki_platform.mount_path
    role_allowed_domains = concat(local.vault_listener_dns_names, [local.vault_service_domain])
    role_allow_ip_sans   = true
    issuer_policy_name   = local.bastion_pki_platform.assignable_policy
    role_ou              = local.state.foundation_libvirt_resources.foundation_pki.map[module.terraform_layer_context.primary_context.pki_key].ou
  }
}

module "helm_chart_cert_manager" {
  count  = local.is_runtime_talos ? 1 : 0
  source = "../../modules/kubernetes-addons/helm-chart-cert-manager"

  helm_config = {
    chart_repository   = local.vault_downstream_chart_repository.cert_manager
    version            = var.helm_chart_version.cert_manager
    kubernetes_version = var.talos_config.kubernetes_version
    namespace          = module.vault_kubernetes_auth_talos[0].kubernetes_identity.cert_manager_namespace
  }
}

module "establish_platform_vault_talos_cluster" {
  count      = local.is_runtime_talos ? 1 : 0
  source     = "../../modules/kvm-provisioning/orchestrate/linux-talos-cluster"
  depends_on = [terraform_data.talos_inputs_validation]

  cluster_identity           = module.terraform_layer_context.cluster_identity
  cluster_network_map        = { (local.vault_downstream_cluster_name) = module.terraform_layer_context.cluster_network }
  network_infrastructure_map = { (local.vault_downstream_cluster_name) = local.state.foundation_libvirt_resources.foundation_topology.infrastructure[local.vault_downstream_cluster_name].network }
  storage_infrastructure_map = local.state.foundation_libvirt_resources.foundation_storage.infrastructure
  talos_iso_path             = "${local.state.foundation_libvirt_resources.foundation_paths.packer_output}/talos-${trimprefix(var.talos_config.talos_version, "v")}/metal-amd64.iso"
  talos_config               = var.talos_config
  volume_config              = var.volume_config

  node_config = {
    for key, spec in var.node_config : key => merge(spec, {
      extra_networks = local.bastion_network_nodes[key]
    })
  }

  inline_manifests = merge(
    module.helm_chart_cilium[0].inline_manifests,
    module.helm_chart_cert_manager[0].inline_manifests,
  )
}

# The kubeconfig and the Talos client credentials follow the cluster lifecycle in the Bastion Vault.
module "credential_vault_talos" {
  count     = local.is_runtime_talos ? 1 : 0
  source    = "gitlab.com/csning1998-lab/provisioner-vault-credential/gitlab"
  version   = "0.1.1"
  providers = { vault = vault.bastion }

  vault_credential_context = {
    kv_namespace = dirname(dirname(local.foundation_kv_paths.cluster_config))
    domain       = basename(dirname(local.foundation_kv_paths.cluster_config))
    component    = basename(local.foundation_kv_paths.cluster_config)
    static = {
      talos_ca_certificate_b64     = module.establish_platform_vault_talos_cluster[0].client_configuration.ca_certificate
      talos_client_certificate_b64 = module.establish_platform_vault_talos_cluster[0].client_configuration.client_certificate
      talos_client_key_b64         = module.establish_platform_vault_talos_cluster[0].client_configuration.client_key
      content_b64                  = base64encode(module.establish_platform_vault_talos_cluster[0].kubeconfig_raw)
    }
  }
}

# The Vault servers log in to the Bastion Vault with a projected ServiceAccount token and receive a token for the
# transit seal. The pgg policy grants encrypt, decrypt, and renew-self on one key alone.
resource "vault_kubernetes_auth_backend_role" "transit_unseal" {
  count    = local.is_runtime_talos ? 1 : 0
  provider = vault.bastion

  backend                          = module.vault_kubernetes_auth_talos[0].cluster_issuer.auth_path
  role_name                        = "${local.vault_downstream_cluster_name}-transit-unseal"
  bound_service_account_names      = [local.vault_workload.service_account]
  bound_service_account_namespaces = [local.vault_workload.namespace]
  audience                         = "${local.vault_downstream_cluster_name}-transit-unseal"

  token_policies          = [local.transit_unseal_consumer.policy_name]
  token_no_default_policy = true
  token_type              = "service"
  token_period            = 60 * 60
  token_bound_cidrs       = local.transit_unseal_source_cidrs
}
