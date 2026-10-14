
variable "cluster_identity" {
  description = "The SSoT identity object of the cluster."
  type = object({
    cluster_name      = string
    node_name_prefix  = string
    storage_pool_name = string
  })
}

variable "cluster_network_map" {
  description = "Pure MECE mapping of calculated network attributes (from foundation-libvirt-resources), keyed by cluster_name. The map MUST contain the entry of this cluster and the entry of every service segment."
  type = map(object({
    segment_key     = string
    cidr_block      = string
    nat_gateway     = string
    nat_cidr_block  = string
    nat_cidr_index  = number
    interface_alias = string
    runtime         = string
    mac_address     = string
    node_ips        = list(string)
    vip             = string
    tags            = list(string)
    ip_range = object({
      start_ip = number
      end_ip   = number
    })
    nat_dhcp = object({
      start = string
      end   = string
    })
    ports = map(object({
      frontend_port            = number
      backend_port             = number
      health_check_type        = string
      health_check_http_path   = string
      health_check_http_expect = string
      health_check_ssl         = bool
      health_check_sni         = optional(string)
      health_check_port        = optional(number)
      send_proxy_v2            = bool
    }))
  }))
}

variable "platform_route_cidrs" {
  description = "Platform networks which every node reaches through the hostonly gateway, matching the route which linux-generic-domain writes into the VM network configuration."
  type        = list(string)
  default     = ["172.16.0.0/16"]

  validation {
    condition     = alltrue([for cidr in var.platform_route_cidrs : can(cidrnetmask(cidr))])
    error_message = "Every platform_route_cidrs entry MUST be an IPv4 CIDR."
  }
}

variable "network_infrastructure_map" {
  description = "Physical NAT and HostOnly network config for the cluster's own segment, keyed by cluster_name."
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

variable "network_service_segments" {
  description = "Service segments which the nodes join. Every node takes the host address at its ip_suffix in each segment."
  type = list(object({
    name        = string
    bridge_name = string
    tags        = optional(list(string))
    cidr        = string
  }))
  default = []
}

variable "storage_infrastructure_map" {
  description = "Volumes of the foundation storage map, keyed by volume key. A volume named <node prefix>-<ip suffix>-<name> attaches to the matching node."
  type = map(object({
    pool_name      = string
    volume_name    = string
    os_disk_format = string
  }))
  default = {}
}

variable "talos_iso_path" {
  description = "Absolute path to the Talos metal ISO which boots every node."
  type        = string
}

variable "node_config" {
  description = "Hardware resources and IP offsets of the control plane nodes, keyed by short keys such as 00. The module names each node <node prefix>-NN in sorted key order. cpu_pin lists one host CPU per vCPU, and null leaves vCPU placement to the host scheduler."
  type = map(object({
    ip_suffix      = number
    vcpu           = number
    ram            = number
    cpu_pin        = optional(list(number))
    extra_networks = optional(map(string), {})
  }))

  validation {
    condition     = alltrue([for key, node in var.node_config : node.cpu_pin == null || length(node.cpu_pin) == node.vcpu])
    error_message = "node_config.cpu_pin MUST list exactly one host CPU per vCPU."
  }

  validation {
    condition     = length(var.node_config) > 0
    error_message = "The cluster requires at least one Talos node."
  }

  validation {
    condition     = alltrue([for key, node in var.node_config : node.vcpu >= 2 && node.ram >= 2048])
    error_message = "Talos control-plane nodes require at least 2 vCPUs and 2048 MiB RAM."
  }
}

variable "talos_config" {
  description = "Talos settings. The talos_version drives the config schema and the installer image, and MUST match the release of the boot ISO. The os_disk_format defaults to raw for the write pattern of etcd. Every node is a control plane member, and allow_scheduling_on_control_planes lets the workloads run on the nodes. The bootstrap_timeout absorbs the install-to-disk and reboot cycle, and the health_timeout covers the Cilium image pull on which kubelet readiness depends."
  type = object({
    talos_version                      = string
    kubernetes_version                 = string
    os_disk_format                     = optional(string, "raw")
    allow_scheduling_on_control_planes = optional(bool, true)
    bootstrap_timeout                  = optional(string, "10m")
    health_timeout                     = optional(string, "15m")
  })

  validation {
    condition     = contains(["raw", "qcow2"], var.talos_config.os_disk_format)
    error_message = "talos_config.os_disk_format must be 'raw' or 'qcow2'."
  }
}

variable "inline_manifests" {
  description = "Manifests applied through cluster.inlineManifests, keyed by manifest name. The cilium entry MUST exist, since the cluster has no CNI before the first boot completes."
  type        = map(string)

  validation {
    condition     = contains(keys(var.inline_manifests), "cilium")
    error_message = "inline_manifests MUST carry the cilium entry."
  }
}

variable "apiserver_config" {
  description = "kube-apiserver settings. authentication_config is an AuthenticationConfiguration document in YAML, which the module writes to every node and passes to kube-apiserver. Null keeps the default authentication. Talos applies a change of the document only after a reboot."
  type = object({
    authentication_config = optional(string)
  })
  default = {}
}

variable "volume_config" {
  description = "Talos user volume mounted at /var/mnt/<name>. volume_type disk formats the data disk at device, and volume_type directory keeps the volume as a directory of the system disk, which needs no data disk. Null leaves the data disk unformatted."
  type = object({
    name        = string
    volume_type = optional(string, "disk")
    device      = optional(string, "/dev/vdb")
  })
  default = null

  validation {
    condition     = var.volume_config == null || contains(["disk", "directory"], var.volume_config.volume_type)
    error_message = "volume_config.volume_type MUST be disk or directory."
  }
}

variable "registry_mirror_config" {
  description = "Pull-through cache which every node uses in place of the upstream registries. The host is the registry host name, the CA is the PEM bundle which verifies the registry certificate, and each mirror maps an upstream domain to a project on the host. Null keeps the upstream registries."
  type = object({
    host    = string
    ca_pem  = string
    mirrors = map(string)
  })
  default = null
}
