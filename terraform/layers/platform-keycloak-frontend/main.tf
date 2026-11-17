
# Declarations which both runtimes share. runtime-vm.tf and runtime-talos.tf contain the declarations of one runtime each.
module "terraform_layer_context" {
  source = "../../modules/kvm-provisioning/helpers/terraform-layer-context"

  guest_usernames              = local.state.foundation_libvirt_resources.foundation_ssh.usernames
  global_pki_map               = local.state.security_vault_downstream_tenants.foundation_pki.map
  global_topology_identity     = local.state.foundation_libvirt_resources.foundation_topology.identity
  global_topology_network      = local.state.foundation_libvirt_resources.foundation_topology.network
  global_network_baseline      = local.state.foundation_libvirt_resources.foundation_network_global.network_baseline
  infrastructure_map           = local.state.foundation_libvirt_resources.foundation_topology.infrastructure
  downstream_vault_service_vip = local.state.security_vault_downstream_tenants.downstream_vault_service_vip
  security_pki_outputs         = local.state.security_vault_downstream_pki

  target_clusters = local.target_clusters
  primary_role    = var.primary_role
  service_config  = var.service_config
}
