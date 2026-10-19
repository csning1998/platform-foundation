
output "generic_cluster" {
  description = "Facts of the SPIRE Parent VM cluster."
  value = {
    service_vip = module.terraform_layer_context.primary_network_config.lb_config.vip
    node_exporter_targets = {
      ips  = module.terraform_layer_context.cluster_network.node_ips
      port = module.terraform_layer_context.node_exporter_port
    }
  }
}

output "spire_agent_bootstrap" {
  description = "Values a SPIRE Agent consumer needs to reach and trust this SPIRE Parent."
  value = {
    node_ip      = one(module.terraform_layer_context.cluster_network.node_ips)
    ssh_host     = "${module.terraform_layer_context.cluster_identity.cluster_name}-node-00"
    trust_domain = local.spiffe_trust_domain
    server_port  = local.spire_server_port
  }
}

output "spire_oidc" {
  description = "OIDC Discovery Provider coordinates and CA certificate of the SPIRE Parent."
  value = {
    auth_backend_path = "${module.terraform_layer_context.cluster_identity.cluster_name}-jwt-svid-provider"
    discovery_url     = "https://${local.spire_parent_node_ip}:${local.spire_oidc_port}"
    discovery_ca_pem  = local.oidc_ca_chain_pem
  }
}

output "spire_upstream_ca_pem" {
  description = "Certificate of pki-intermediate-spire, the upstream root of the SPIRE trust bundle, which an upstream agent of the SPIRE Child trusts before its first attestation."
  value       = local.bastion_pki_spire.cert_pem
}
