
# Declarations of the Talos runtime alone. Each resource and module declares count = local.is_runtime_talos ? 1 : 0.
resource "terraform_data" "talos_inputs_validation" {
  count = local.is_runtime_talos ? 1 : 0
  input = local.keycloak_cluster_runtime

  lifecycle {
    precondition {
      condition     = var.talos_config != null && var.helm_chart_version != null && length(var.node_config) > 0
      error_message = "The Talos runtime of keycloak requires talos_config, helm_chart_version, and node_config."
    }
  }
}

# The Downstream PKI layer owns the leaf role of this component.
module "vault_auth_keycloak_talos" {
  count     = local.is_runtime_talos ? 1 : 0
  source    = "../../modules/vault-provisioning/vault-kubernetes-auth"
  providers = { vault = vault.downstream }

  cluster_name = local.keycloak_cluster_name
  pki_config = {
    mount_path         = local.state.security_vault_downstream_pki.downstream_pki_configuration.path
    role_name          = local.state.security_vault_downstream_pki.downstream_pki_configuration.leaf_roles["keycloak-frontend"].name
    issuer_policy_name = local.terraform_operator.cluster_issuer_policy
  }
  external_secrets_config = {
    kv_paths    = [local.downstream_kv_paths["keycloak"]["frontend"].app]
    policy_name = local.terraform_operator.external_secrets_policy
  }
}

module "helm_chart_cilium" {
  count  = local.is_runtime_talos ? 1 : 0
  source = "../../modules/kubernetes-addons/helm-chart-cilium"

  helm_config = {
    chart_repository   = local.harbor_registry_mirror.chart_repository
    version            = var.helm_chart_version.cilium
    kubernetes_version = var.talos_config.kubernetes_version
  }
  cilium_config = {
    kubeprism_port = var.talos_config.kubeprism_port
    node_count     = length(var.node_config)
    mtu            = local.state.foundation_libvirt_resources.foundation_network_global.network_baseline.global_mtu
    gateway_api    = var.talos_config.gateway_api
  }
}

module "helm_chart_cert_manager" {
  count  = local.is_runtime_talos ? 1 : 0
  source = "../../modules/kubernetes-addons/helm-chart-cert-manager"

  helm_config = {
    chart_repository   = local.harbor_registry_mirror.chart_repository
    version            = var.helm_chart_version.cert_manager
    kubernetes_version = var.talos_config.kubernetes_version
    namespace          = module.vault_auth_keycloak_talos[0].kubernetes_identity.cert_manager_namespace
  }
}

module "helm_chart_external_secrets" {
  count  = local.is_runtime_talos ? 1 : 0
  source = "../../modules/kubernetes-addons/helm-chart-external-secrets"

  helm_config = {
    chart_repository   = local.harbor_registry_mirror.chart_repository
    version            = var.helm_chart_version.external_secrets
    kubernetes_version = var.talos_config.kubernetes_version
    namespace          = module.vault_auth_keycloak_talos[0].kubernetes_identity.external_secrets_namespace
  }
}

module "establish_platform_keycloak_talos_cluster" {
  count      = local.is_runtime_talos ? 1 : 0
  source     = "../../modules/kvm-provisioning/orchestrate/linux-talos-cluster"
  depends_on = [terraform_data.talos_inputs_validation]

  cluster_identity           = module.terraform_layer_context.cluster_identity
  cluster_network_map        = { (local.keycloak_cluster_name) = module.terraform_layer_context.cluster_network }
  network_infrastructure_map = { (local.keycloak_cluster_name) = local.state.foundation_libvirt_resources.foundation_topology.infrastructure[local.keycloak_cluster_name].network }
  storage_infrastructure_map = local.state.foundation_libvirt_resources.foundation_storage.infrastructure
  talos_iso_path             = "${local.state.foundation_libvirt_resources.foundation_paths.packer_output}/talos-${trimprefix(var.talos_config.talos_version, "v")}/metal-amd64.iso"
  talos_config               = var.talos_config
  node_config                = var.node_config
  volume_config              = var.volume_config

  registry_mirror_config = {
    host    = local.harbor_registry_mirror.host
    ca_pem  = base64decode(local.state.security_vault_downstream_pki.bastion_pki_chain_b64.content_b64)
    mirrors = local.harbor_registry_mirror.mirrors
  }

  inline_manifests = merge(
    module.helm_chart_cilium[0].inline_manifests,
    module.helm_chart_cert_manager[0].inline_manifests,
    module.helm_chart_external_secrets[0].inline_manifests,
  )
}

# The kubeconfig and the Talos client credentials follow the cluster lifecycle in the Downstream Vault.
module "credential_keycloak_talos" {
  count     = local.is_runtime_talos ? 1 : 0
  source    = "gitlab.com/csning1998-lab/provisioner-vault-credential/gitlab"
  version   = "0.1.1"
  providers = { vault = vault.downstream }

  vault_credential_context = {
    kv_namespace = dirname(dirname(local.state.foundation_libvirt_resources.foundation_vault_path.kv_paths["keycloak"]["frontend"].cluster_config))
    domain       = basename(dirname(local.state.foundation_libvirt_resources.foundation_vault_path.kv_paths["keycloak"]["frontend"].cluster_config))
    component    = basename(local.state.foundation_libvirt_resources.foundation_vault_path.kv_paths["keycloak"]["frontend"].cluster_config)
    static = {
      talos_ca_certificate_b64     = module.establish_platform_keycloak_talos_cluster[0].client_configuration.ca_certificate
      talos_client_certificate_b64 = module.establish_platform_keycloak_talos_cluster[0].client_configuration.client_certificate
      talos_client_key_b64         = module.establish_platform_keycloak_talos_cluster[0].client_configuration.client_key
      content_b64                  = base64encode(module.establish_platform_keycloak_talos_cluster[0].kubeconfig_raw)
    }
  }
}
