
# GitLab HTTP backend base URL. Authentication credentials must be supplied via
# `TF_HTTP_USERNAME` and `TF_HTTP_PASSWORD` environment variables.
locals {
  _state_base_platform_foundation = "https://gitlab.com/api/v4/projects/84608830/terraform/state"
}

locals {
  state = {
    foundation_libvirt_resources      = data.terraform_remote_state.foundation_libvirt_resources.outputs
    security_vault_downstream_tenants = data.terraform_remote_state.security_vault_downstream_tenants.outputs
    platform_spire_parent             = data.terraform_remote_state.platform_spire_parent.outputs
    security_vault_downstream_pki     = data.terraform_remote_state.security_vault_downstream_pki.outputs
  }
}

locals {
  # The operator of the SPIRE Child logs in to the Downstream Vault with the JWT-SVID of the SPIRE Parent.
  terraform_operator_subject = { service = "spire", component = "child" }
  terraform_operator         = local.state.security_vault_downstream_tenants.downstream_vault_operators[local.terraform_operator_subject.service][local.terraform_operator_subject.component]

  spire_child_cluster_identity = local.state.foundation_libvirt_resources.foundation_topology.identity["spire"]["child"]
  spire_child_cluster_network  = local.state.foundation_libvirt_resources.foundation_topology.network["spire"]["child"]
  spire_child_cluster_name     = local.spire_child_cluster_identity.cluster_name
  spire_child_chart_repository = "oci://quay.io/cilium/charts"
}

# The OIDC discovery provider and the agent service of the SPIRE Child take the static VIPs following the control plane VIP.
locals {
  spire_child_endpoints = {
    oidc_vip  = cidrhost(local.spire_child_cluster_network.cidr_block, local.state.foundation_libvirt_resources.foundation_network_global.network_baseline.host_vip_offset + 1)
    agent_vip = cidrhost(local.spire_child_cluster_network.cidr_block, local.state.foundation_libvirt_resources.foundation_network_global.network_baseline.host_vip_offset + 2)
  }
  spire_child_oidc_issuer   = "https://${local.spire_child_endpoints.oidc_vip}"
  spiffe_trust_domain       = local.state.platform_spire_parent.spire_agent_bootstrap.trust_domain
  kubernetes_jwt_audience   = local.spire_child_cluster_name
  kubernetes_operator_group = "spire-owner-operator"
}

# kube-apiserver trusts the JWT-SVIDs of the SPIRE Child, whose subject becomes the user name. Only an identity below
# /<owner>/terraform-operator/ joins the operator group of its owner, which the registration RBAC of provision-spire-child grants.
locals {
  kube_apiserver_authentication_config = yamlencode({
    apiVersion = "apiserver.config.k8s.io/v1"
    kind       = "AuthenticationConfiguration"
    jwt = [{
      issuer = {
        url                  = local.spire_child_oidc_issuer
        audiences            = [local.kubernetes_jwt_audience]
        certificateAuthority = base64decode(local.state.security_vault_downstream_pki.bastion_pki_chain_b64.content_b64)
      }
      claimValidationRules = [{
        expression = "claims.sub.startsWith(\"spiffe://${local.spiffe_trust_domain}/\")"
        message    = "the subject MUST belong to the trust domain ${local.spiffe_trust_domain}"
      }]
      claimMappings = {
        username = { expression = "claims.sub" }
        groups = {
          expression = "claims.sub.split(\"/\").size() > 5 && claims.sub.split(\"/\")[4] == \"terraform-operator\" ? [\"${local.kubernetes_operator_group}:\" + claims.sub.split(\"/\")[3]] : []"
        }
      }
    }]
  })
}
