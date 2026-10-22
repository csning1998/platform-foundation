
module "linux_generic_domain" {
  source = "../../configure/linux-generic-domain"

  guest_config = local.guest_config

  create_networks        = false
  credentials            = local.guest_hypervisor_credentials
  libvirt_infrastructure = local.hypervisor_kvm_infrastructure
  static_routes          = var.static_routes
}

# Host SSH keys MUST originate from pre-boot cryptographic generation
# to populate client known_hosts files before guest network initialization.
resource "local_file" "known_hosts" {
  filename             = pathexpand("~/.ssh/known_hosts_${var.cluster_identity.cluster_name}")
  file_permission      = "0644"
  directory_permission = "0700"
  content = join("", [
    for k, v in local.flat_node_map :
    "${v.ip} ${module.linux_generic_domain.guest_host_public_keys[k]}\n"
  ])
}

# Provisioning execution MUST block until guests complete SSH handshakes
# to bridge the convergence interval between domain creation and operating system readiness.
resource "sshclient_reachability" "guest_ready" {
  depends_on = [module.linux_generic_domain, local_file.known_hosts]

  config_name = var.cluster_identity.cluster_name
  hosts       = [for k, v in local.flat_node_map : v.ip]
}

module "ansible_runner" {
  source         = "../../configure/ansible-runner"
  depends_on     = [sshclient_reachability.guest_ready]
  status_trigger = { (var.cluster_identity.cluster_name) = local_file.known_hosts.id }

  inventory_data = local.ansible_inventory_data
  playbook_paths = local.ansible_playbook_paths

  ansible_config = {
    # This value MUST remain unset because OpenSSH honors only the first -o occurrence of an option,
    # and a fixed value overrides the per-cluster Host block which MUST govern both the primary
    # connection and any delegate_to on another node.
    known_hosts_path  = null
    identity_key_path = null
    root_path         = local.ansible.root_path
    inventory_file    = local.ansible.inventory_file
  }

  extra_vars = local.ansible_extra_vars
}
