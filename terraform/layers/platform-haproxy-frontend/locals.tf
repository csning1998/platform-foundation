# GitLab HTTP backend base URL. Authentication credentials must be supplied via
# `TF_HTTP_USERNAME` and `TF_HTTP_PASSWORD` environment variables.
locals {
  _state_base_platform_foundation = "https://gitlab.com/api/v4/projects/84608830/terraform/state"
}

locals {
  state = {
    foundation_libvirt_resources = data.terraform_remote_state.foundation_libvirt_resources.outputs
  }
}

locals {
  foundation_project_code = local.state.foundation_libvirt_resources.foundation_vault_path.project_code
  haproxy_cluster_name    = local.state.foundation_libvirt_resources.foundation_topology.identity["haproxy"]["frontend"].cluster_name

  haproxy_runtime = local.state.foundation_libvirt_resources.foundation_topology.infrastructure[local.haproxy_cluster_name].runtime
}

# HAProxy precedes the Downstream Vault, which a VM runtime of the Downstream Vault exposes through the VIP of HAProxy.
# The layer therefore depends on the Bastion Vault alone, and each registry field holds one category in JSON.
locals {
  registry_bastion = {
    for field, value in nonsensitive(data.vault_generic_secret.registry_bastion.data) : field => jsondecode(value)
  }
  bastion_pki_platform   = local.registry_bastion.pki.constrained_intermediates["pki-leaf-platform"]
  bastion_pki_downstream = local.registry_bastion.pki.constrained_intermediates["pki-intermediate-vault-downstream"]

  bastion_pki_platform_cert_pem   = local.bastion_pki_platform.issuer_certs[local.bastion_pki_platform.root_ca_id]
  bastion_pki_downstream_cert_pem = local.bastion_pki_downstream.issuer_certs[local.bastion_pki_downstream.root_ca_id]

  # The backends present certificates of pki-leaf-platform or of the Downstream issuer below pki-intermediate-vault-downstream.
  backend_ca_bundle_pem = join("\n", concat(
    [
      for root_id in distinct([
        local.bastion_pki_platform.root_ca_id,
        local.bastion_pki_downstream.root_ca_id,
      ]) : trimspace(local.registry_bastion.pki.trust_anchors[root_id])
    ],
    [
      trimspace(local.bastion_pki_platform_cert_pem),
      trimspace(local.bastion_pki_downstream_cert_pem),
      "",
    ]
  ))
}

# Kubernetes-native runtimes stay on the Cilium Service/L2Announcement path. Any other
# runtime in the catalog is an external service, owned end to end by this tier per the
# decisions.md entry retiring Cilium Service exposure for non-Kubernetes backends.
locals {
  kubernetes_native_runtimes = local.state.foundation_libvirt_resources.foundation_topology.kubernetes_native_runtimes

  fronted_segments = {
    for key, seg in local.state.foundation_libvirt_resources.foundation_topology.infrastructure : key => seg
    if key != local.haproxy_cluster_name
    && !contains(local.kubernetes_native_runtimes, seg.runtime)
    && seg.lb_config.vip != null
    && length(seg.backend_servers) > 0
  }
}

# Each fronted segment becomes one extra NIC on every HAProxy node, attached to the
# already-existing hostonly network for that segment. A static per-node address keeps
# the Keepalived VRRP peer list deterministic without relying on DHCP.
locals {
  haproxy_extra_ip_offset = 240

  sorted_node_keys = sort(keys(var.service_config[var.primary_role].nodes))

  haproxy_extra_networks_by_node = {
    for idx, node_key in local.sorted_node_keys : node_key => {
      for seg_key, seg in local.fronted_segments :
      seg.network.hostonly.name => "${cidrhost(seg.network.hostonly.cidr, local.haproxy_extra_ip_offset + idx)}/${seg.network.hostonly.prefix}"
    }
  }

  service_config = {
    for role, cfg in var.service_config : role => merge(cfg, {
      nodes = {
        for node_key, node in cfg.nodes : node_key => merge(node, {
          extra_networks = role == var.primary_role ? local.haproxy_extra_networks_by_node[node_key] : {}
        })
      }
    })
  }
}

# Backend list for the platform_haproxy_frontend Ansible role, read from the same infrastructure_map
# feeding the Cilium manifests. Both stay derived from one Terraform source.
locals {
  lb_service_segments = [
    for seg_key, seg in local.fronted_segments : {
      name            = seg_key
      vip             = seg.lb_config.vip
      cidr            = seg.network.hostonly.cidr
      gateway         = seg.network.hostonly.gateway
      interface_alias = module.interface_alias[seg_key].alias
      vrid            = tonumber(split(".", seg.network.hostonly.cidr)[2])
      ports           = seg.lb_config.ports
      backend_servers = seg.backend_servers
    }
  ]

  fronted_segment_vrids = [for seg in local.lb_service_segments : seg.vrid]

  # extra_networks addresses HAProxy assigns itself on a fronted segment must not collide with
  # the backend node addresses or the VIP already reserved on that same segment.
  extra_network_offset_conflicts = flatten([
    for seg_key, seg in local.fronted_segments : [
      for idx in range(length(local.sorted_node_keys)) :
      seg_key
      if contains(
        concat([for server in seg.backend_servers : server.ip], [seg.lb_config.vip]),
        cidrhost(seg.network.hostonly.cidr, local.haproxy_extra_ip_offset + idx)
      )
    ]
  ])
}

locals {
  # ansible_host resolves through the operator SSH config alias, meaningless inside the
  # guest. The stats listener needs the real address on this segment.
  haproxy_node_ips = [
    for node_key, node in var.service_config[var.primary_role].nodes :
    cidrhost(module.terraform_layer_context.primary_network_config.network.hostonly.cidr, node.ip_suffix)
  ]
  haproxy_listen_address = sort(local.haproxy_node_ips)[0]

  ansible_template_config = {
    global_mss   = module.terraform_layer_context.global_mss
    access_scope = module.terraform_layer_context.primary_network_config.network.hostonly.cidr
  }

  # Every value is public. The play issues the stats certificate and mints the credentials through the Vault Proxy, outside the state.
  ansible_extra_config = {
    lb_service_segments                   = jsonencode(local.lb_service_segments)
    haproxy_stats_port                    = module.terraform_layer_context.primary_network_config.lb_config.ports["stats"].frontend_port
    haproxy_listen_address                = local.haproxy_listen_address
    haproxy_credential_kv_path            = local.state.foundation_libvirt_resources.foundation_vault_path.kv_paths["haproxy"]["frontend"].app
    platform_haproxy_ca_bundle_b64        = base64encode(local.backend_ca_bundle_pem)
    platform_haproxy_pki_mount            = vault_pki_secret_backend_role.stats.backend
    platform_haproxy_pki_role             = vault_pki_secret_backend_role.stats.name
    platform_haproxy_common_name          = local.state.foundation_libvirt_resources.foundation_pki.map[module.terraform_layer_context.primary_context.pki_key].dns_san[0]
    platform_haproxy_alt_names            = join(",", local.state.foundation_libvirt_resources.foundation_pki.map[module.terraform_layer_context.primary_context.pki_key].dns_san)
    platform_haproxy_ip_sans              = join(",", module.terraform_layer_context.cluster_network.node_ips)
    platform_haproxy_metrics_source_cidrs = jsonencode(var.observability_config.scraper_cidrs)
  }

  haproxy_pki_role_name = module.terraform_layer_context.cluster_identity.cluster_name
}

check "haproxy_vrid_valid" {
  assert {
    condition     = alltrue([for v in local.fronted_segment_vrids : v >= 1 && v <= 255])
    error_message = "Every fronted segment's derived VRID must fall within the valid VRRP range [1, 255]."
  }
  assert {
    condition     = length(local.fronted_segment_vrids) == length(distinct(local.fronted_segment_vrids))
    error_message = "Two fronted segments derived the same VRID; VRRP requires a unique virtual_router_id per L2 segment."
  }
}

check "haproxy_extra_network_offsets_safe" {
  assert {
    condition     = length(local.extra_network_offset_conflicts) == 0
    error_message = "haproxy_extra_ip_offset collides with a fronted segment's own reserved node ip_range for: ${join(", ", local.extra_network_offset_conflicts)}."
  }
}

# Cluster names derive from the foundation topology, so no input carries the project code.
locals {
  target_clusters = {
    for role, c in var.target_components :
    role => local.state.foundation_libvirt_resources.foundation_topology.identity[c.service][c.component].cluster_name
  }
}
