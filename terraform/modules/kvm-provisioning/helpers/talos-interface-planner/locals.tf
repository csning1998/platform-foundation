
locals {
  cluster_sorted_node_keys = sort(keys(var.node_config))
  network_mac_parts        = split(":", var.cluster_network.mac_address)
}

locals {
  network_node_interfaces = {
    for node_name, node_spec in var.node_config : node_name => concat(
      # Interface 1: NAT (Management)
      [{
        network_name = var.network_infra.nat.name
        mac = format("%s:%s:%s:00:%s:%02x",
          local.network_mac_parts[0],
          local.network_mac_parts[1],
          local.network_mac_parts[2],
          local.network_mac_parts[4],
          (parseint(local.network_mac_parts[5], 16) + index(local.cluster_sorted_node_keys, node_name)) % 256
        )
        addresses = []
      }],

      # Interface 2: HostOnly (Internal, has the node static IP)
      [{
        network_name = var.network_infra.hostonly.name
        mac = format("%s:%s:%s:%s:%s:%02x",
          local.network_mac_parts[0],
          local.network_mac_parts[1],
          local.network_mac_parts[2],
          local.network_mac_parts[3],
          local.network_mac_parts[4],
          (parseint(local.network_mac_parts[5], 16) + index(local.cluster_sorted_node_keys, node_name)) % 256
        )
        addresses = [
          format("%s/%s",
            cidrhost(var.cluster_network.cidr_block, node_spec.ip_suffix),
            split("/", var.cluster_network.cidr_block)[1]
          )
        ]
      }],

      # Interface 3..N: One per service segment [ens5+]
      [
        for seg_name in var.service_segment_names : {
          network_name = seg_name
          alias        = var.cluster_network_map[seg_name].interface_alias
          mac = format("%s:%02x",
            join(":", slice(split(":", var.cluster_network_map[seg_name].mac_address), 0, 5)),
            (parseint(element(split(":", var.cluster_network_map[seg_name].mac_address), 5), 16) + index(local.cluster_sorted_node_keys, node_name)) % 256
          )
          addresses = [
            format("%s/%s",
              cidrhost(var.cluster_network_map[seg_name].cidr_block, node_spec.ip_suffix),
              split("/", var.cluster_network_map[seg_name].cidr_block)[1]
            )
          ]
        }
      ],

      # Generates deterministic MAC addresses from extra network CIDR strings to prevent inter-cluster collisions.
      [
        for net in sort(keys(node_spec.extra_networks)) : {
          network_name = net
          mac          = module.deterministic_mac.macs["${node_name}/${net}"]
          addresses    = [node_spec.extra_networks[net]]
        }
      ]
    )
  }
}

locals {
  cluster_vm_config = {
    storage_pool_name = var.storage_pool_name
    nodes = {
      for node_name, node_spec in var.node_config : node_name => {
        vcpu                 = node_spec.vcpu
        ram                  = node_spec.ram
        os_disk_capacity_gib = node_spec.os_disk_capacity_gib
        interfaces           = local.network_node_interfaces[node_name]
      }
    }
  }
}
