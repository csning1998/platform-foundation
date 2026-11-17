# Keycloak workload of the Talos runtime. On the VM runtime the platform layer deploys Keycloak through Ansible,
# hence every declaration below declares count = local.is_runtime_talos ? 1 : 0.
locals {
  keycloak_workload = {
    namespace         = "keycloak"
    tls_secret_name   = "keycloak-tls"
    credential_secret = "keycloak-credentials"
  }
}

resource "kubernetes_namespace_v1" "keycloak" {
  count      = local.is_runtime_talos ? 1 : 0
  depends_on = [ephemeral.talos_cluster_health.this]

  metadata {
    name = local.keycloak_workload.namespace
    labels = {
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "baseline"
      "pod-security.kubernetes.io/warn"    = "baseline"
    }
  }
}

# The database claim lives on the Talos user volume of the platform layer and survives a release removal.
module "local_path_provisioner" {
  count      = local.is_runtime_talos ? 1 : 0
  source     = "../../modules/kubernetes-addons/local-path-provisioner"
  depends_on = [ephemeral.talos_cluster_health.this]

  helm_config = {
    chart_repository = var.talos_workload_config.local_path_provisioner_chart_repository
    version          = var.talos_workload_config.local_path_provisioner_chart_version
  }
  storage_config = {
    node_path      = local.state.platform_keycloak_frontend.talos_cluster.volume_mount_path
    reclaim_policy = "Retain"
  }
}

# The PKI role of keycloak-frontend admits the names of the component and IP SANs, hence the certificate also contains the VIP.
module "keycloak_listener_certificate" {
  count  = local.is_runtime_talos ? 1 : 0
  source = "../../modules/kubernetes-addons/platform-certificate"

  certificate_config = {
    name         = local.keycloak_workload.tls_secret_name
    namespace    = kubernetes_namespace_v1.keycloak[0].metadata[0].name
    common_name  = local.keycloak_fqdn.keycloak_frontend
    dns_names    = local.state.security_vault_downstream_tenants.foundation_pki.map["keycloak-frontend"].dns_san
    ip_addresses = [local.keycloak_cluster_vip]
    usages       = ["digital signature", "server auth"]
  }
  issuer_ref = module.platform_cluster_issuer[0].cluster_issuer
}

# The credentials of security-vault-downstream-credentials reach the cluster through the ClusterSecretStore of trust.tf.
resource "kubernetes_manifest" "keycloak_credentials" {
  count = local.is_runtime_talos ? 1 : 0

  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.keycloak_workload.credential_secret
      namespace = kubernetes_namespace_v1.keycloak[0].metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { kind = "ClusterSecretStore", name = kubernetes_manifest.downstream_vault_store[0].manifest.metadata.name }
      target          = { name = local.keycloak_workload.credential_secret }
      data = [
        for field in ["keycloak_admin_user", "keycloak_admin_password", "keycloak_db_user", "keycloak_db_password"] : {
          secretKey = field
          remoteRef = { key = local.downstream_kv_paths["keycloak"]["frontend"].app, property = field }
        }
      ]
    }
  }

  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
}

module "manifest_keycloak" {
  count  = local.is_runtime_talos ? 1 : 0
  source = "../../modules/kubernetes-addons/manifest-keycloak"
  depends_on = [
    module.keycloak_listener_certificate,
    kubernetes_manifest.keycloak_credentials,
  ]

  keycloak_config = {
    namespace       = kubernetes_namespace_v1.keycloak[0].metadata[0].name
    image           = var.talos_workload_config.keycloak_image
    hostname        = local.keycloak_fqdn.keycloak_frontend
    tls_secret_name = local.keycloak_workload.tls_secret_name
    resources       = var.talos_workload_config.keycloak_resources
  }
  database_config = {
    image              = var.talos_workload_config.postgres_image
    storage_class_name = module.local_path_provisioner[0].storage_class_name
    storage_size       = var.talos_workload_config.database_storage_size
  }
  credential_secret = {
    name               = local.keycloak_workload.credential_secret
    admin_user_key     = "keycloak_admin_user"
    admin_password_key = "keycloak_admin_password"
    db_user_key        = "keycloak_db_user"
    db_password_key    = "keycloak_db_password"
  }
  service_config = {
    external_ip = local.keycloak_cluster_vip
  }
}
