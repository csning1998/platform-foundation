
# Declarations of the Talos runtime alone. Each data source, ephemeral resource, resource, and module carries
# count = local.is_runtime_talos ? 1 : 0, and every local below stays null on the VM runtime.
locals {
  vault_downstream_talos_cluster = local.state.platform_vault_downstream_frontend.talos_cluster

  # The Downstream Vault precedes Harbor Origin, hence every chart comes from its upstream repository.
  vault_downstream_chart_repository = {
    local_path_provisioner = "oci://ghcr.io/rancher/local-path-provisioner/charts"
    vault                  = "https://helm.releases.hashicorp.com"
  }

  # Each registry field holds one category in JSON. The facts are not secret, while the provider marks every KV value as sensitive.
  registry_bastion = local.is_runtime_talos ? {
    for field, value in nonsensitive(data.vault_generic_secret.registry_bastion[0].data) : field => jsondecode(value)
  } : null

  vault_downstream_kubeconfig = local.is_runtime_talos ? yamldecode(base64decode(ephemeral.vault_kv_secret_v2.vault_cluster[0].data["content_b64"])) : null

  vault_downstream_api_server_connection = local.is_runtime_talos ? {
    host               = local.vault_downstream_kubeconfig.clusters[0].cluster.server
    ca_cert            = base64decode(local.vault_downstream_kubeconfig.clusters[0].cluster["certificate-authority-data"])
    client_certificate = base64decode(local.vault_downstream_kubeconfig.users[0].user["client-certificate-data"])
    client_key         = base64decode(local.vault_downstream_kubeconfig.users[0].user["client-key-data"])
    } : {
    host               = null
    ca_cert            = null
    client_certificate = null
    client_key         = null
  }

  ansible_config = {
    root_path      = abspath("${path.root}/../../../ansible")
    inventory_file = "inventory-provision-vault-downstream-frontend.yaml"
  }

  inventory_data = {
    all = {
      children = {
        vault_downstream_bootstrap = {
          hosts = {
            "host-terraform-operator-workstation" = {
              ansible_connection         = "local"
              ansible_python_interpreter = "/usr/bin/python3"
            }
          }
        }
      }
    }
  }
}

resource "terraform_data" "talos_inputs_validation" {
  count = local.is_runtime_talos ? 1 : 0
  input = local.vault_downstream_runtime.name

  lifecycle {
    precondition {
      condition     = var.helm_chart_version != null
      error_message = "The Talos runtime of vault-downstream requires helm_chart_version."
    }
  }
}

# parent-group-governance publishes the Bastion facts of the tenant in the registry, in place of its Terraform state.
data "vault_generic_secret" "registry_bastion" {
  count    = local.is_runtime_talos ? 1 : 0
  provider = vault.bastion
  path     = "registry/${local.foundation_project_code}/bastion"
}

ephemeral "vault_kv_secret_v2" "vault_cluster" {
  count    = local.is_runtime_talos ? 1 : 0
  provider = vault.bastion
  mount    = "secret"
  name     = local.foundation_kv_paths.cluster_config
}

# Cluster readiness checks MUST re-validate quorum convergence during apply operations.
ephemeral "talos_cluster_health" "this" {
  count = local.is_runtime_talos ? 1 : 0

  client_configuration = {
    ca_certificate     = ephemeral.vault_kv_secret_v2.vault_cluster[0].data["talos_ca_certificate_b64"]
    client_certificate = ephemeral.vault_kv_secret_v2.vault_cluster[0].data["talos_client_certificate_b64"]
    client_key         = ephemeral.vault_kv_secret_v2.vault_cluster[0].data["talos_client_key_b64"]
  }
  control_plane_nodes = values(local.vault_downstream_talos_cluster.hostonly_addresses)
  endpoints           = values(local.vault_downstream_talos_cluster.hostonly_addresses)

  timeout = "10m"
}

# Every read of the Kubernetes API waits for the health check, since the OpenAPI request of the provider times out on a converging API server.
data "kubernetes_config_map_v1" "root_ca" {
  count      = local.is_runtime_talos ? 1 : 0
  depends_on = [ephemeral.talos_cluster_health.this]

  metadata {
    name      = "kube-root-ca.crt"
    namespace = "kube-system"
  }
}

# Guards against early CRD admission failures before the webhook endpoints are ready.
data "kubernetes_resource" "cert_manager_webhook" {
  count      = local.is_runtime_talos ? 1 : 0
  depends_on = [ephemeral.talos_cluster_health.this]

  api_version = "apps/v1"
  kind        = "Deployment"

  metadata {
    name      = "cert-manager-webhook"
    namespace = local.vault_downstream_talos_cluster.cluster_issuer.namespace
  }

  lifecycle {
    postcondition {
      condition     = coalesce(self.object.status.availableReplicas, 0) >= 1
      error_message = "The cert-manager webhook is not available yet. Apply again after the Deployment reports an available replica."
    }
  }
}

# Vault validates the ServiceAccount tokens of this cluster through the TokenReview API of the cluster.
# The token reviewer authenticates to the API server on its own, with the VIP of the cluster and its root CA.
module "vault_token_reviewer" {
  count      = local.is_runtime_talos ? 1 : 0
  source     = "../../modules/kubernetes-addons/vault-token-reviewer"
  depends_on = [ephemeral.talos_cluster_health.this]
  providers  = { vault = vault.bastion }

  api_server_connection = {
    host    = "https://${local.vault_endpoint.service_vip}:6443"
    ca_cert = data.kubernetes_config_map_v1.root_ca[0].data["ca.crt"]
  }
  vault_auth_path          = local.vault_downstream_talos_cluster.cluster_issuer.auth_path
  reviewer_service_account = { namespace = local.vault_downstream_talos_cluster.cluster_issuer.namespace }
}

module "platform_cluster_issuer" {
  count      = local.is_runtime_talos ? 1 : 0
  source     = "../../modules/kubernetes-addons/platform-cluster-issuer"
  depends_on = [data.kubernetes_resource.cert_manager_webhook, module.vault_token_reviewer]

  vault_config = {
    address   = local.registry_bastion.vault.endpoint
    auth_path = module.vault_token_reviewer[0].vault_auth_path
    ca_cert   = local.registry_bastion.vault.listener_ca_cert_pem
  }
  issuer_config = local.vault_downstream_talos_cluster.cluster_issuer
}

# The raft data stays on the Talos user volume of each node, which outlives the pods.
module "local_path_provisioner" {
  count      = local.is_runtime_talos ? 1 : 0
  source     = "../../modules/kubernetes-addons/local-path-provisioner"
  depends_on = [ephemeral.talos_cluster_health.this]

  helm_config = {
    chart_repository = local.vault_downstream_chart_repository.local_path_provisioner
    version          = var.helm_chart_version.local_path_provisioner
  }
  storage_config = {
    node_path      = local.vault_downstream_talos_cluster.volume_mount_path
    reclaim_policy = "Retain"
  }
}

resource "kubernetes_namespace_v1" "vault" {
  count      = local.is_runtime_talos ? 1 : 0
  depends_on = [ephemeral.talos_cluster_health.this]

  metadata {
    name = local.vault_downstream_talos_cluster.vault_workload.namespace
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "baseline"
      "pod-security.kubernetes.io/warn"    = "baseline"
    }
  }
}

# pki-leaf-platform rejects a loopback and a bare name, hence the certificate carries the cluster domain names of the chart.
module "vault_listener_certificate" {
  count  = local.is_runtime_talos ? 1 : 0
  source = "../../modules/kubernetes-addons/platform-certificate"

  certificate_config = {
    name         = "vault-listener-tls"
    namespace    = kubernetes_namespace_v1.vault[0].metadata[0].name
    common_name  = local.state.platform_vault_downstream_frontend.listener_identity.common_name
    dns_names    = concat(local.state.platform_vault_downstream_frontend.listener_identity.dns_names, module.helm_chart_vault[0].listener_names.dns_names)
    ip_addresses = local.state.platform_vault_downstream_frontend.listener_identity.ip_addresses
  }
  issuer_ref = module.platform_cluster_issuer[0].cluster_issuer
}

module "helm_chart_vault" {
  count  = local.is_runtime_talos ? 1 : 0
  source = "../../modules/kubernetes-addons/helm-chart-vault"

  helm_config = {
    chart_repository = local.vault_downstream_chart_repository.vault
    version          = var.helm_chart_version.vault
    namespace        = kubernetes_namespace_v1.vault[0].metadata[0].name
  }
  raft_config = {
    replicas = length(local.vault_downstream_talos_cluster.hostonly_addresses)
  }
  vault_config = {
    tls_secret_name = module.vault_listener_certificate[0].secret_name
    storage_class   = module.local_path_provisioner[0].storage_class_name
    storage_size    = var.vault_config.storage_size
    service_account = local.vault_downstream_talos_cluster.vault_workload.service_account
  }
  service_config = {
    external_ip = local.vault_endpoint.service_vip
  }

  # The servers auto-unseal against the Bastion Vault transit engine per decisions.md.
  transit_seal_config = merge(local.vault_downstream_talos_cluster.transit_unseal, {
    ca_cert_pem = local.registry_bastion.vault.listener_ca_cert_pem
  })
}

# The play initializes the first server and writes the root token and the recovery keys to the init leaf of the
# Bastion Vault through the platform-foundation Vault Proxy. The servers unseal through the transit seal.
# The play reruns on a new release revision.
module "vault_bootstrap" {
  count  = local.is_runtime_talos ? 1 : 0
  source = "../../modules/kvm-provisioning/configure/ansible-runner"

  ansible_config = local.ansible_config
  inventory_data = local.inventory_data
  playbook_paths = ["${local.ansible_config.root_path}/playbooks/playbook_provision.yaml"]
  status_trigger = { (module.helm_chart_vault[0].vault_servers.namespace) = module.helm_chart_vault[0].vault_servers.release }
  extra_vars = {
    provision_vault_downstream_kubeconfig_kv_path = local.foundation_kv_paths.cluster_config
    provision_vault_downstream_init_kv_path       = local.foundation_kv_paths.init
    provision_vault_downstream_ca_cert_path       = local.vault_endpoint.ca_cert_path
    provision_vault_downstream_namespace          = module.helm_chart_vault[0].vault_servers.namespace
    provision_vault_downstream_container          = module.helm_chart_vault[0].vault_servers.container
    provision_vault_downstream_seal               = module.helm_chart_vault[0].vault_servers.seal
    provision_vault_downstream_pods               = jsonencode(module.helm_chart_vault[0].vault_servers.pods)
    provision_vault_downstream_health_url         = "https://${local.vault_endpoint.service_vip}:443/v1/sys/health"
  }
}
