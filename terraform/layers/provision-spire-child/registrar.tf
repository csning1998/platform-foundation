# The registrar credential lets the Terraform operators and the join token flow run spire-server in the pod of the Child server.
# The Role names the pod, and the credential therefore does not grant any other access to the Child cluster.
resource "kubernetes_service_account_v1" "registrar" {
  metadata {
    name      = local.spire_child_chart.registrar_sa
    namespace = kubernetes_namespace_v1.spire_server.metadata[0].name
  }
}

resource "kubernetes_role_v1" "registrar" {
  metadata {
    name      = local.spire_child_chart.registrar_sa
    namespace = kubernetes_namespace_v1.spire_server.metadata[0].name
  }

  rule {
    api_groups     = [""]
    resources      = ["pods"]
    resource_names = [local.spire_child_chart.internal_server_pod]
    verbs          = ["get"]
  }

  # A WebSocket exec authorizes get, and an SPDY exec authorizes create.
  rule {
    api_groups     = [""]
    resources      = ["pods/exec"]
    resource_names = [local.spire_child_chart.internal_server_pod]
    verbs          = ["get", "create"]
  }
}

resource "kubernetes_role_binding_v1" "registrar" {
  metadata {
    name      = local.spire_child_chart.registrar_sa
    namespace = kubernetes_namespace_v1.spire_server.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.registrar.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.registrar.metadata[0].name
    namespace = kubernetes_service_account_v1.registrar.metadata[0].namespace
  }
}

resource "kubernetes_secret_v1" "registrar_token" {
  metadata {
    name      = local.spire_child_chart.registrar_sa
    namespace = kubernetes_service_account_v1.registrar.metadata[0].namespace
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account_v1.registrar.metadata[0].name
    }
  }
  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

# The kubeconfig resides in the Downstream KV. The operators of the downstream components read the path with their own policy.
resource "vault_kv_secret_v2" "registrar" {
  provider = vault.downstream

  mount = "secret"
  name  = local.spire_child_kv_paths.registrar

  data_json = jsonencode({
    content_b64 = base64encode(yamlencode({
      apiVersion        = "v1"
      kind              = "Config"
      "current-context" = local.spire_child_cluster_name
      clusters = [{
        name = local.spire_child_cluster_name
        cluster = {
          server                       = local.spire_child_api_server_vip_url
          "certificate-authority-data" = base64encode(data.kubernetes_config_map_v1.root_ca.data["ca.crt"])
        }
      }]
      users = [{
        name = local.spire_child_chart.registrar_sa
        user = { token = kubernetes_secret_v1.registrar_token.data["token"] }
      }]
      contexts = [{
        name    = local.spire_child_cluster_name
        context = { cluster = local.spire_child_cluster_name, user = local.spire_child_chart.registrar_sa }
      }]
    }))
  })
}
