
# The chart renders to a manifest, since Talos applies the manifest at bootstrap before the API server exists.
# The platform consumes ExternalSecret and ClusterSecretStore alone. The machine configuration excludes the CRDs of the other kinds.
data "helm_template" "external_secrets" {
  name         = "external-secrets"
  namespace    = var.helm_config.namespace
  chart        = "${var.helm_config.chart_repository}/external-secrets"
  version      = var.helm_config.version
  kube_version = var.helm_config.kubernetes_version

  values = [yamlencode({
    installCRDs = true
    crds = {
      createClusterExternalSecret = false
      createSecretStore           = false
      createClusterGenerator      = false
      createClusterPushSecret     = false
      createPushSecret            = false
    }
    processClusterExternalSecret = false
    processSecretStore           = false
    processClusterGenerator      = false
    processClusterPushSecret     = false
    processPushSecret            = false
  })]
}
