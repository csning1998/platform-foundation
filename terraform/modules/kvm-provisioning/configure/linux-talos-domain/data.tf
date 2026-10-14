
data "libvirt_domain_interface_addresses" "nodes" {
  for_each = var.talos_cluster_vm_config.nodes

  # Domain interface address queries require domain UUIDs. Numeric domain runtime IDs (`id`) are rejected.
  domain = libvirt_domain.nodes[each.key].uuid
  source = "lease"

  # Postcondition checks MUST validate lease list boundaries to provide diagnostic node identification upon failure.
  lifecycle {
    postcondition {
      condition = length([
        for addr in flatten([
          for iface in self.interfaces :
          iface.addrs if lower(iface.hwaddr) == lower(var.talos_cluster_vm_config.nodes[each.key].interfaces[0].mac)
        ]) : addr.addr if addr.type == "ipv4"
      ]) == 1
      error_message = "Expected exactly one IPv4 DHCP lease on the NAT interface (MAC ${var.talos_cluster_vm_config.nodes[each.key].interfaces[0].mac}) for node '${each.key}'; the maintenance-mode address is not yet stable."
    }
  }
}
