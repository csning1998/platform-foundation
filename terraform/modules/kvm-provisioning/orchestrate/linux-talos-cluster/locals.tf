
# Cluster Topology
locals {
  cluster_naming_map = {
    for idx, key in sort(keys(var.node_config)) : key => "${var.cluster_identity.node_name_prefix}-${format("%02d", idx)}"
  }
  cluster_nodes = {
    for key, spec in var.node_config : local.cluster_naming_map[key] => spec
  }

  cluster_sorted_keys   = sort(keys(local.cluster_nodes))
  cluster_bootstrap_key = local.cluster_sorted_keys[0]
}

# Network Infrastructure & Service Routing
locals {
  network_primary            = var.cluster_network_map[var.cluster_identity.cluster_name]
  network_infrastructure     = var.network_infrastructure_map[var.cluster_identity.cluster_name]
  network_hostonly_addresses = module.linux_talos_domain.hostonly_addresses

  # The rule priorities start ahead of the main table rule at 32766, and the table number stays clear of the reserved 253 to 255.
  network_hostonly_link = {
    alias         = "hostonly"
    route_table   = "100"
    rule_priority = 1000
  }

  network_service_segments = [
    for seg in var.network_service_segments : merge(seg, {
      node_ips = { for name, spec in local.cluster_nodes : name => cidrhost(seg.cidr, spec.ip_suffix) }
    })
  ]
}

# Storage Infrastructure & Volume Patches
locals {
  # The foundation layer names a data volume "<node prefix>-<ip suffix>-<name>". The attached volumes follow the sorted volume keys.
  storage_attached_volumes = {
    for name, spec in local.cluster_nodes : name => [
      for vol_key in sort(keys(var.storage_infrastructure_map)) : {
        pool           = var.storage_infrastructure_map[vol_key].pool_name
        volume         = var.storage_infrastructure_map[vol_key].volume_name
        os_disk_format = var.storage_infrastructure_map[vol_key].os_disk_format
      }
      if startswith(vol_key, "${var.cluster_identity.node_name_prefix}-${spec.ip_suffix}-")
    ]
  }

  # The user volume formats the data disk and mounts the disk at /var/mnt/<name>.
  storage_volume_patches = var.volume_config == null ? [] : [yamlencode({
    apiVersion = "v1alpha1"
    kind       = "UserVolumeConfig"
    name       = var.volume_config.name
    provisioning = {
      diskSelector = { match = "disk.dev_path == '${var.volume_config.device}'" }
      minSize      = "1GiB"
    }
  })]
}

# Machine Configuration & Manifests
locals {
  # Talos 1.13 declares registry mirrors as separate documents. overridePath keeps the project path of the pull-through cache.
  config_registry_patches = var.registry_mirror_config == null ? [] : concat(
    [for domain, project in var.registry_mirror_config.mirrors : yamlencode({
      apiVersion = "v1alpha1"
      kind       = "RegistryMirrorConfig"
      name       = domain
      endpoints  = [{ url = "https://${var.registry_mirror_config.host}/v2/${project}", overridePath = true }]
    })],
    [yamlencode({
      apiVersion = "v1alpha1"
      kind       = "RegistryTLSConfig"
      name       = var.registry_mirror_config.host
      ca         = var.registry_mirror_config.ca_pem
    })]
  )

  # The cilium manifest comes first. The other manifests follow in key order.
  config_inline_manifests = concat(
    [{ name = "cilium", contents = var.inline_manifests["cilium"] }],
    [for name in sort(keys(var.inline_manifests)) : { name = name, contents = var.inline_manifests[name] } if name != "cilium"]
  )
}

# Cluster VM Specification & Endpoint
locals {
  # The control plane VIP MUST bind to the canonical service catalog address
  # through Talos leader election to provide a resilient cluster endpoint.
  cluster_endpoint = "https://${local.network_primary.vip}:6443"

  cluster_vm_config = {
    storage_pool_name = module.talos_interface_planner.cluster_vm_config.storage_pool_name
    nodes = {
      for name, node in module.talos_interface_planner.cluster_vm_config.nodes : name => {
        vcpu                 = node.vcpu
        ram                  = node.ram
        os_disk_capacity_gib = node.os_disk_capacity_gib
        interfaces           = node.interfaces
        cpu_pin              = local.cluster_nodes[name].cpu_pin
        attached_volumes     = local.storage_attached_volumes[name]
      }
    }
  }
}

check "talos_iso_present" {
  assert {
    condition     = fileexists(var.talos_iso_path)
    error_message = "Talos ISO missing at ${var.talos_iso_path}. Build it via packer before applying this layer."
  }
}

check "node_count_matches_catalog" {
  assert {
    condition     = length(var.node_config) == length(local.network_primary.node_ips)
    error_message = "node_config MUST declare one node per address of the ip_range in the service catalog."
  }
}

check "data_disk_attached" {
  assert {
    condition     = var.volume_config == null || alltrue([for name, volumes in local.storage_attached_volumes : length(volumes) > 0])
    error_message = "Every node requires one data volume from the foundation storage map, named <node prefix>-<ip suffix>-<name>."
  }
}
