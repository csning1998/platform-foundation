
locals {
  release_name = "vault"
  tls_dir      = "/vault/userconfig/${var.vault_config.tls_secret_name}"

  # The listener certificate contains names under the cluster domain alone because pki-platform rejects a bare name or a loopback.
  service_domain = "${var.helm_config.namespace}.svc.${var.raft_config.cluster_domain}"
  peer_names     = [for ordinal in range(var.raft_config.replicas) : "${local.release_name}-${ordinal}.${local.release_name}-internal.${local.service_domain}"]

  retry_join = join("\n", [
    for name in local.peer_names : <<-EOT
      retry_join {
        leader_api_addr       = "https://${name}:8200"
        leader_ca_cert_file   = "${local.tls_dir}/ca.crt"
        leader_tls_servername = "${name}"
      }
    EOT
  ])

  raft_config = <<-EOT
    ui = true

    listener "tcp" {
      address         = "[::]:8200"
      cluster_address = "[::]:8201"
      tls_cert_file   = "${local.tls_dir}/tls.crt"
      tls_key_file    = "${local.tls_dir}/tls.key"
    }

    storage "raft" {
      path = "/vault/data"
    ${local.retry_join}
    }

    service_registration "kubernetes" {}
  EOT
}

locals {
  transit_enabled = var.transit_seal_config != null
  transit_paths = {
    seal_dir   = "/vault/transit-seal"
    ca_dir     = "/vault/transit-seal-ca"
    token_dir  = "/vault/transit-seal-token"
    seal_file  = "/vault/transit-seal/seal.hcl"
    ca_file    = "/vault/transit-seal-ca/ca.crt"
    token_file = "/vault/transit-seal-token/token"
  }

  # The script never echoes the token. umask 077 leaves the stanza readable by the user of the server alone.
  transit_login_script = local.transit_enabled ? join("\n", [
    "set -eu",
    "umask 077",
    "token=$(VAULT_ADDR='${var.transit_seal_config.address}' VAULT_CACERT='${local.transit_paths.ca_file}' vault write -field=token 'auth/${var.transit_seal_config.auth_path}/login' role='${var.transit_seal_config.role_name}' jwt=@${local.transit_paths.token_file})",
    "cat > ${local.transit_paths.seal_file} <<EOF",
    "seal \"transit\" {",
    "  address     = \"${var.transit_seal_config.address}\"",
    "  token       = \"$token\"",
    "  mount_path  = \"${var.transit_seal_config.mount_path}/\"",
    "  key_name    = \"${var.transit_seal_config.key_name}\"",
    "  tls_ca_cert = \"${local.transit_paths.ca_file}\"",
    "}",
    "EOF",
  ]) : ""

  # The for expression evaluates the body only when the seal is enabled, and merge of no object yields an empty object.
  transit_values = merge([for enabled in [local.transit_enabled] : {
    extraArgs = "-config=${local.transit_paths.seal_file}"
    volumes = [
      { name = "transit-seal", emptyDir = { medium = "Memory" } },
      { name = "transit-seal-ca", configMap = { name = kubernetes_config_map_v1.transit_seal_ca[0].metadata[0].name } },
      {
        name = "transit-seal-token"
        projected = {
          sources = [{
            serviceAccountToken = {
              path              = "token"
              audience          = var.transit_seal_config.audience
              expirationSeconds = 600
            }
          }]
        }
      },
    ]
    volumeMounts = [
      { name = "transit-seal", mountPath = local.transit_paths.seal_dir, readOnly = true },
      { name = "transit-seal-ca", mountPath = local.transit_paths.ca_dir, readOnly = true },
    ]
    extraInitContainers = [{
      name    = "transit-seal-login"
      image   = "hashicorp/vault:${var.vault_config.image_tag}"
      command = ["/bin/sh", "-c", local.transit_login_script]
      volumeMounts = [
        { name = "transit-seal", mountPath = local.transit_paths.seal_dir },
        { name = "transit-seal-ca", mountPath = local.transit_paths.ca_dir, readOnly = true },
        { name = "transit-seal-token", mountPath = local.transit_paths.token_dir, readOnly = true },
      ]
      securityContext = {
        allowPrivilegeEscalation = false
        capabilities             = { drop = ["ALL"] }
      }
    }]
  } if enabled]...)
}

# The upstream listener CA is public. The init container and the seal verify the upstream Vault against the CA.
resource "kubernetes_config_map_v1" "transit_seal_ca" {
  count = local.transit_enabled ? 1 : 0

  metadata {
    name      = "${local.release_name}-transit-seal-ca"
    namespace = var.helm_config.namespace
  }

  data = {
    "ca.crt" = var.transit_seal_config.ca_cert_pem
  }
}

# The chart renders no secret. The listener key resides in the Secret which cert-manager writes, and the transit token
# resides in the memory volume of each pod.
resource "helm_release" "vault" {
  name       = local.release_name
  repository = var.helm_config.chart_repository
  chart      = "vault"
  version    = var.helm_config.version
  namespace  = var.helm_config.namespace
  timeout    = var.helm_config.timeout

  # A sealed server reports unready, and each server remains sealed until the transit seal or the operator unseals the server.
  wait = false

  values = [yamlencode({
    global   = { tlsDisable = false }
    injector = { enabled = false }
    server = merge({
      image          = { repository = "hashicorp/vault", tag = var.vault_config.image_tag }
      serviceAccount = { create = true, name = var.vault_config.service_account }
      # The CLI inside a server reaches the listener at 127.0.0.1 and verifies the certificate against the Service name.
      extraEnvironmentVars = {
        VAULT_CACERT          = "${local.tls_dir}/ca.crt"
        VAULT_TLS_SERVER_NAME = "${local.release_name}.${local.service_domain}"
      }
      extraVolumes = [{ type = "secret", name = var.vault_config.tls_secret_name }]
      dataStorage = {
        enabled      = true
        size         = var.vault_config.storage_size
        storageClass = var.vault_config.storage_class
      }
      ha = {
        enabled  = true
        replicas = var.raft_config.replicas
        raft = {
          enabled   = true
          setNodeId = true
          config    = local.raft_config
        }
      }
    }, local.transit_values)
  })]
}

# The chart Service lacks externalIPs. This Service selects the active server, as the active Service of the chart does.
resource "kubernetes_service_v1" "external" {
  depends_on = [helm_release.vault]

  metadata {
    name      = "${local.release_name}-external"
    namespace = var.helm_config.namespace
  }

  spec {
    type         = "ClusterIP"
    external_ips = [var.service_config.external_ip]

    selector = {
      "app.kubernetes.io/name" = local.release_name
      "component"              = "server"
      "vault-active"           = "true"
    }

    port {
      name        = "https"
      port        = var.service_config.port
      target_port = 8200
      protocol    = "TCP"
    }
  }
}
