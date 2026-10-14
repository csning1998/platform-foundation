
variable "create_networks" {
  description = "Controls network resource creation within the module. Set false when networks are pre-provisioned by foundation-libvirt-resources."
  type        = bool
  default     = true
}

variable "talos_iso_path" {
  description = "Absolute file path to the shared Talos Metal installation ISO boot media."
  type        = string
}

variable "os_disk_format" {
  description = "OS disk volume format. Talos runs etcd, which performs poorly on copy-on-write formats stacked over a copy-on-write host filesystem. Defaults to raw; set qcow2 to opt back into thin provisioning and snapshots."
  type        = string
  default     = "raw"

  validation {
    condition     = contains(["raw", "qcow2"], var.os_disk_format)
    error_message = "os_disk_format must be 'raw' or 'qcow2'."
  }
}

variable "talos_cluster_vm_config" {
  description = "Talos node specifications defining hardware resources and ordered interface bindings (NAT, HostOnly, followed by service segments)."
  type = object({
    storage_pool_name = string
    nodes = map(object({
      vcpu                 = number
      ram                  = number
      cpu_pin              = optional(list(number))
      os_disk_capacity_gib = optional(number, 40)

      # Pre-provisioned volumes, which foundation-libvirt-resources creates. The volumes attach after the OS disk in list order.
      attached_volumes = optional(list(object({
        pool           = string
        volume         = string
        os_disk_format = string
      })), [])

      interfaces = list(object({
        network_name = string
        mac          = string
        alias        = optional(string)
        addresses    = optional(list(string), [])
      }))
    }))
  })

  validation {
    condition = alltrue([
      for node in values(var.talos_cluster_vm_config.nodes) :
      length(node.interfaces) >= 2 && length(node.interfaces[1].addresses) >= 1
    ])
    error_message = "Every node requires at least two interfaces, with interfaces[1] (the HostOnly interface) carrying at least one static address."
  }
}

variable "network_infrastructure" {
  description = "HostOnly and NAT network specifications keyed by cluster_name. NAT includes DHCP allocation for initial maintenance-mode bootstrap."
  type = map(object({
    hostonly = object({
      name        = string
      bridge_name = string
      gateway     = string
      prefix      = number
      mtu         = number
    })
    nat = object({
      name        = string
      bridge_name = string
      gateway     = string
      prefix      = number
      mtu         = number
      dhcp = optional(object({
        start = string
        end   = string
      }))
    })
    access_scope = optional(string)
  }))
}

variable "talos_cluster_service_segments" {
  description = "Service segment network definitions for infrastructure creation, matching the network_service_segments schema consumed by talos-interface-planner."
  type = list(object({
    name        = string
    bridge_name = string
    cidr        = string
    tags        = optional(list(string))
  }))
}
