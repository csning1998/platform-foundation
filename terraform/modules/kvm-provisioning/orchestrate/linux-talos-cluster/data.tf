
data "talos_cluster_health" "this" {
  depends_on = [talos_machine_bootstrap.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  control_plane_nodes  = values(local.network_hostonly_addresses)
  endpoints            = values(local.network_hostonly_addresses)

  timeouts = {
    read = var.talos_config.health_timeout
  }
}

# Fixed-size clusters combine control-plane and workload tasks to satisfy etcd quorum and resource constraints.
data "talos_machine_configuration" "this" {
  for_each = local.cluster_vm_config.nodes

  cluster_name       = var.cluster_identity.cluster_name
  machine_type       = "controlplane"
  cluster_endpoint   = local.cluster_endpoint
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  kubernetes_version = var.talos_config.kubernetes_version
  talos_version      = var.talos_config.talos_version

  config_patches = concat(
    local.storage_volume_patches,
    local.config_registry_patches,
    local.apiserver_authentication_patches,
    [
      yamlencode({
        machine = {
          # Explicitly set installer image URI to align installed image release with running ISO media version.
          install = {
            disk  = "/dev/vda"
            image = "ghcr.io/siderolabs/installer:${var.talos_config.talos_version}"
          }
          # A node with network documents runs DHCP on declared interfaces alone, and the apply reaches the node on the
          # NAT lease. The hostonly interface lives in the documents below, and service segments carry static addresses.
          network = {
            interfaces = concat(
              [{
                deviceSelector = { hardwareAddr = each.value.interfaces[0].mac }
                dhcp           = true
              }],
              [
                for iface in slice(each.value.interfaces, 2, length(each.value.interfaces)) : {
                  deviceSelector = { hardwareAddr = iface.mac }
                  dhcp           = false
                  addresses      = iface.addresses
                }
              ],
            )
          }
          # Pin kubelet node IP binding explicitly to the service subnet CIDR block.
          kubelet = { nodeIP = { validSubnets = [local.network_primary.cidr_block] } }
        }
        cluster = {
          network                        = { cni = { name = "none" } }
          proxy                          = { disabled = true }
          allowSchedulingOnControlPlanes = var.talos_config.allow_scheduling_on_control_planes
          etcd = {
            advertisedSubnets = [local.network_primary.cidr_block]
            # Heartbeat intervals MUST be increased beyond baseline defaults
            # because hypervisor scheduling jitter triggers spurious etcd leader elections.
            extraArgs = {
              "election-timeout"   = "2500"
              "heartbeat-interval" = "250"
            }
          }
          inlineManifests = local.config_inline_manifests
        }
      }),
      # The dnsmasq of the hostonly gateway holds the platform names, which the Talos default public resolvers lack.
      yamlencode({
        apiVersion  = "v1alpha1"
        kind        = "ResolverConfig"
        nameservers = [{ address = local.network_infrastructure.hostonly.gateway }]
      }),
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "LinkAliasConfig"
        name       = local.network_hostonly_link.alias
        selector   = { match = "mac(link.permanent_addr) == \"${each.value.interfaces[1].mac}\"" }
      }),
      # Platform networks without a direct leg route through the hostonly gateway. A reply from a hostonly address
      # follows the table of the rule below since a reply over the direct leg of a service segment bypasses the host,
      # and the host conntrack then drops the next forwarded packet of the connection as invalid.
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "LinkConfig"
        name       = local.network_hostonly_link.alias
        up         = true
        addresses  = [for address in each.value.interfaces[1].addresses : { address = address }]
        routes = concat(
          [for cidr in var.platform_route_cidrs : { destination = cidr, gateway = local.network_infrastructure.hostonly.gateway, metric = 100 }],
          [
            { destination = local.network_primary.cidr_block, table = local.network_hostonly_link.route_table },
            { gateway = local.network_infrastructure.hostonly.gateway, table = local.network_hostonly_link.route_table },
          ],
        )
      }),
    ],
    # A rule without a destination prefix would also catch replies to pods, whose routes live in the main table alone.
    [
      for idx, cidr in var.platform_route_cidrs : yamlencode({
        apiVersion = "v1alpha1"
        kind       = "RoutingRuleConfig"
        name       = tostring(local.network_hostonly_link.rule_priority + idx)
        src        = local.network_primary.cidr_block
        dst        = cidr
        table      = local.network_hostonly_link.route_table
      })
    ],
    [
      yamlencode({
        apiVersion = "v1alpha1"
        kind       = "Layer2VIPConfig"
        name       = local.network_primary.vip
        link       = local.network_hostonly_link.alias
      }),
    ],
  )
}
