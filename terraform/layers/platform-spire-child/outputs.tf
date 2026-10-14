
output "foundation_topology" {
  description = "Pass-through of the foundation-libvirt-resources topology object."
  value       = local.state.foundation_libvirt_resources.foundation_topology
}

output "foundation_network_global" {
  description = "Pass-through of the foundation-libvirt-resources global facts object."
  value       = local.state.foundation_libvirt_resources.foundation_network_global
}

output "foundation_pki" {
  description = "Pass-through of the foundation-libvirt-resources PKI object."
  value       = local.state.foundation_libvirt_resources.foundation_pki
}

output "foundation_vault_path" {
  description = "Pass-through of the foundation-libvirt-resources Vault path object."
  value       = local.state.foundation_libvirt_resources.foundation_vault_path
}

output "foundation_ssh" {
  description = "Pass-through of foundation SSH metadata for downstream SPIRE parent host connectivity."
  value       = local.state.foundation_libvirt_resources.foundation_ssh
}

output "spire_child_endpoints" {
  description = "Static VIPs of the OIDC discovery provider and of the agent service of the SPIRE Child, the issuer which kube-apiserver and the Child JWT backend trust, the audience of a JWT-SVID for the Kubernetes API, and the group prefix of the owner operators."
  value = merge(local.spire_child_endpoints, {
    oidc_issuer               = local.spire_child_oidc_issuer
    kubernetes_jwt_audience   = local.kubernetes_jwt_audience
    kubernetes_operator_group = local.kubernetes_operator_group
  })
}

output "talos_cluster" {
  description = "Facts of the SPIRE Child Talos cluster."
  value = {
    hostonly_addresses = module.establish_platform_spire_child_talos_cluster.hostonly_addresses
    bootstrap_node_key = module.establish_platform_spire_child_talos_cluster.bootstrap_node_key
    volume_mount_path  = module.establish_platform_spire_child_talos_cluster.volume_mount_path
  }
}
