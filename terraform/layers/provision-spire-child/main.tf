
# Pre-creates namespaces before Helm chart deployment to enforce explicit Pod Security Standards (PSS):
# spire-system requires 'privileged' admission for the CSI driver and agent DaemonSets, while spire-server enforces 'restricted'.
resource "kubernetes_namespace_v1" "spire_system" {
  depends_on = [ephemeral.talos_cluster_health.this]

  metadata {
    name = local.spire_child_chart.system_namespace
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

resource "kubernetes_namespace_v1" "spire_server" {
  depends_on = [ephemeral.talos_cluster_health.this]

  metadata {
    name = local.spire_child_chart.server_namespace
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

# The upstream agent trusts pki-spire, the upstream root of the SPIRE trust bundle, for its first connection to the SPIRE Parent.
resource "kubernetes_config_map_v1" "upstream_bundle" {
  metadata {
    name      = local.spire_child_chart.upstream_bundle_cm
    namespace = kubernetes_namespace_v1.spire_system.metadata[0].name
  }

  data = {
    (local.spire_child_chart.upstream_bundle_field) = local.state.platform_spire_parent.spire_upstream_ca_pem
  }
}

# The Downstream PKI issues the listener certificate of the OIDC discovery provider, which the Child JWT backend verifies.
resource "vault_pki_secret_backend_role" "oidc_discovery" {
  provider = vault.downstream

  backend = local.state.security_vault_downstream_pki.downstream_pki_configuration.path
  name    = local.spire_child_cluster_name

  allowed_domains    = local.state.platform_spire_child.foundation_pki.map["spire-child"].dns_san
  allow_bare_domains = true
  allow_subdomains   = false
  allow_glob_domains = false
  allow_ip_sans      = true
  enforce_hostnames  = true
  require_cn         = true
  allow_any_name     = false

  key_type    = "ec"
  key_bits    = 256
  key_usage   = ["DigitalSignature"]
  server_flag = true
  client_flag = false

  max_ttl = 60 * 60 * 24 * 90 # 90 Days
  ttl     = 60 * 60 * 24 * 30 # 30 Days

  ou = local.state.platform_spire_child.foundation_pki.map["spire-child"].ou
}

resource "vault_pki_secret_backend_cert" "oidc_discovery" {
  provider = vault.downstream

  backend     = vault_pki_secret_backend_role.oidc_discovery.backend
  name        = vault_pki_secret_backend_role.oidc_discovery.name
  common_name = local.state.platform_spire_child.foundation_pki.map["spire-child"].dns_san[0]
  alt_names   = local.state.platform_spire_child.foundation_pki.map["spire-child"].dns_san
  ip_sans     = [local.spire_child_oidc_vip]

  auto_renew            = true
  min_seconds_remaining = 60 * 60 * 24 * 7 # 7 Days
}

resource "kubernetes_secret_v1" "oidc_discovery_tls" {
  metadata {
    name      = local.spire_child_chart.oidc_tls_secret
    namespace = kubernetes_namespace_v1.spire_server.metadata[0].name
  }
  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = "${vault_pki_secret_backend_cert.oidc_discovery.certificate}\n${vault_pki_secret_backend_cert.oidc_discovery.issuing_ca}"
    "tls.key" = vault_pki_secret_backend_cert.oidc_discovery.private_key
  }
}

# Dedicated Cilium IP pool and L2 announcement policy publish the child SPIRE OIDC discovery endpoint.
resource "kubernetes_manifest" "oidc_ip_pool" {
  depends_on = [ephemeral.talos_cluster_health.this]

  manifest = {
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumLoadBalancerIPPool"
    metadata   = { name = "${local.spire_child_cluster_name}-oidc-discovery" }
    spec = {
      serviceSelector = { matchLabels = local.spire_child_oidc_service_labels }
      blocks          = [{ cidr = "${local.spire_child_oidc_vip}/32" }]
    }
  }
}

resource "kubernetes_manifest" "oidc_l2_announcement" {
  depends_on = [ephemeral.talos_cluster_health.this]

  manifest = {
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumL2AnnouncementPolicy"
    metadata   = { name = "${local.spire_child_cluster_name}-oidc-discovery" }
    spec = {
      serviceSelector = { matchLabels = local.spire_child_oidc_service_labels }
      loadBalancerIPs = true
    }
  }
}

locals {
  spire_child_oidc_service_labels = {
    "io.kubernetes.service.namespace" = local.spire_child_chart.server_namespace
    "io.kubernetes.service.name"      = local.spire_child_chart.oidc_service_name
  }

  spire_child_agent_service_labels = {
    "io.kubernetes.service.namespace" = local.spire_child_chart.server_namespace
    "io.kubernetes.service.name"      = local.spire_child_chart.internal_server_service
  }
}

# The child server serves the agents of every downstream VM and of the operator workstation on the static agent VIP.
resource "kubernetes_manifest" "agent_ip_pool" {
  depends_on = [ephemeral.talos_cluster_health.this]

  manifest = {
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumLoadBalancerIPPool"
    metadata   = { name = "${local.spire_child_cluster_name}-agent-endpoint" }
    spec = {
      serviceSelector = { matchLabels = local.spire_child_agent_service_labels }
      blocks          = [{ cidr = "${local.spire_child_agent_vip}/32" }]
    }
  }
}

resource "kubernetes_manifest" "agent_l2_announcement" {
  depends_on = [ephemeral.talos_cluster_health.this]

  manifest = {
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumL2AnnouncementPolicy"
    metadata   = { name = "${local.spire_child_cluster_name}-agent-endpoint" }
    spec = {
      serviceSelector = { matchLabels = local.spire_child_agent_service_labels }
      loadBalancerIPs = true
    }
  }
}

# CRD installation MUST complete before spire-nested chart evaluates ClusterSPIFFEID resources.
resource "helm_release" "spire_crds" {
  depends_on = [ephemeral.talos_cluster_health.this]

  name       = "spire-crds"
  repository = "https://spiffe.github.io/helm-charts-hardened/"
  chart      = "spire-crds"
  version    = var.spire_crds_chart_version
  namespace  = kubernetes_namespace_v1.spire_server.metadata[0].name
}

# SPIRE parent workload registration MUST precede chart deployment to prevent upstream agent attestation failures.
resource "helm_release" "spire_nested" {
  depends_on = [
    module.spire_parent_registration,
    helm_release.spire_crds,
    kubernetes_config_map_v1.upstream_bundle,
    kubernetes_secret_v1.oidc_discovery_tls,
    kubernetes_manifest.oidc_ip_pool,
    kubernetes_manifest.oidc_l2_announcement,
    kubernetes_manifest.agent_ip_pool,
    kubernetes_manifest.agent_l2_announcement,
  ]

  name       = "spire"
  repository = "https://spiffe.github.io/helm-charts-hardened/"
  chart      = "spire-nested"
  version    = var.spire_nested_chart_version
  namespace  = kubernetes_namespace_v1.spire_server.metadata[0].name
  wait       = true
  timeout    = 900

  values = [yamlencode(local.spire_nested_values)]
}

locals {
  spire_nested_values = {
    tags = { nestedChildFull = true }

    global = {
      spire = {
        clusterName = local.spire_child_cluster_name
        trustDomain = local.spiffe_trust_domain
        jwtIssuer   = local.spire_child_jwt_issuer
        caSubject = {
          country      = var.spire_child_ca_subject_country
          organization = local.spire_child_project_code
          commonName   = local.spire_child_cluster_name
        }
        recommendations = { enabled = true }
        namespaces      = { create = false }
      }
    }

    # In-cluster external root server deployment is disabled in favor of upstream bare-metal/VM parent federation.
    "external-root-spire-server-full" = { enabled = false }

    "upstream-spire-agent" = {
      trustBundleFormat = "pem"
      server = {
        address = local.spire_parent.node_ip
        port    = local.spire_parent.server_port
      }
    }

    "internal-spire-server" = {
      # The datastore holds the attested agents and the entries registered through the CLI, which a reboot MUST NOT erase.
      persistence = { type = "hostPath", hostPath = local.state.platform_spire_child.talos_cluster.volume_mount_path }
      # Talos creates the user volume as root, and the server image runs as 1000:1000.
      initContainers = [{
        name            = local.spire_child_chart.datastore_init_container
        image           = local.spire_child_chart.datastore_init_image
        command         = ["chown", "1000:1000", "/run/spire/data"]
        securityContext = { runAsUser = 0, runAsNonRoot = false }
        volumeMounts    = [{ name = "spire-data", mountPath = "/run/spire/data" }]
      }]

      # Agents outside the cluster reach the server through the agent VIP and attest with a single use join token.
      service = {
        type        = "LoadBalancer"
        port        = local.spire_child_agent_port
        annotations = { "lbipam.cilium.io/ips" = local.spire_child_agent_vip }
      }
      nodeAttestor = { joinToken = { enabled = true } }

      upstreamAuthority = {
        spire = {
          server = {
            address = local.spire_parent.node_ip
            port    = local.spire_parent.server_port
          }
        }
      }
    }

    "spiffe-oidc-discovery-provider" = {
      tls = {
        spire          = { enabled = false }
        externalSecret = { enabled = true, secretName = local.spire_child_chart.oidc_tls_secret }
      }
      service = {
        type        = "LoadBalancer"
        annotations = { "lbipam.cilium.io/ips" = local.spire_child_oidc_vip }
      }
    }
  }
}
