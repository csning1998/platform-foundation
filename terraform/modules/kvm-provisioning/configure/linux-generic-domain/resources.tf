
data "local_file" "ssh_public_key" {
  filename = pathexpand(var.credentials.ssh_public_key_path)
}

module "interface_alias" {
  source   = "../../helpers/interface-alias"
  for_each = toset(flatten([for k, v in var.guest_config.all_nodes_map : keys(v.extra_networks)]))

  name = each.key
}

resource "terraform_data" "node_mac_uniqueness" {
  lifecycle {
    precondition {
      condition = (
        length(flatten([
          for k, v in local.nodes_config : concat(
            [v.nat_mac, v.hostonly_mac],
            [for net, iface in v.extra_network_interfaces : iface.mac]
          )
          ])) == length(distinct(flatten([
            for k, v in local.nodes_config : concat(
              [v.nat_mac, v.hostonly_mac],
              [for net, iface in v.extra_network_interfaces : iface.mac]
            )
        ])))
      )
      error_message = "Duplicate nat_mac, hostonly_mac, or extra_network_interfaces MAC entry detected among nodes in this linux-generic-domain invocation."
    }
  }
}

resource "libvirt_network" "nat_net" {

  for_each = var.create_networks ? {
    for k, v in var.libvirt_infrastructure : k => v
    if v.network.nat.mode != "route"
  } : {}

  name      = each.value.network.nat.name_network
  autostart = true

  bridge = {
    name = each.value.network.nat.name_bridge
  }

  forward = {
    mode = each.value.network.nat.mode
  }

  ips = [
    {
      address = each.value.network.nat.ips.address
      prefix  = each.value.network.nat.ips.prefix
      dhcp = each.value.network.nat.ips.dhcp != null ? {
        ranges = [
          {
            start = each.value.network.nat.ips.dhcp.start
            end   = each.value.network.nat.ips.dhcp.end
          }
        ]
      } : null
    }
  ]
}

resource "libvirt_network" "hostonly_net" {

  for_each = var.create_networks ? {
    for k, v in var.libvirt_infrastructure : k => v
    if v.network.hostonly.mode != "route"
  } : {}

  name      = each.value.network.hostonly.name_network
  autostart = true

  bridge = {
    name = each.value.network.hostonly.name_bridge
  }

  forward = {
    mode = each.value.network.hostonly.mode
  }

  ips = [
    {
      address = each.value.network.hostonly.ips.address
      prefix  = each.value.network.hostonly.ips.prefix

      dhcp = each.value.network.hostonly.ips.dhcp != null ? {
        ranges = [
          {
            start = each.value.network.hostonly.ips.dhcp.start
            end   = each.value.network.hostonly.ips.dhcp.end
          }
        ]
      } : null
    }
  ]
}

resource "libvirt_volume" "base_image" {
  for_each = local.base_image_map

  name = "base-${each.key}"
  pool = values(var.libvirt_infrastructure)[0].storage_pool_name
  target = {
    format = {
      type = "qcow2"
    }
  }

  create = {
    content = {
      url = each.value
    }
  }
}

# The backing_store overlay mechanism is qcow2-only. A raw target volume is declared
# empty here at the target capacity. An Ansible role converts base_image content into
# the raw volume path (qemu-img convert) before first boot.
resource "libvirt_volume" "os_disk" {
  depends_on = [libvirt_volume.base_image]

  for_each = var.guest_config.all_nodes_map
  name     = "${each.key}-os.${var.os_disk_format}"
  pool     = values(var.libvirt_infrastructure)[0].storage_pool_name
  capacity = each.value.os_disk_capacity_gib * 1024 * 1024 * 1024

  target = {
    format = {
      type = var.os_disk_format
    }
  }

  backing_store = var.os_disk_format == "qcow2" ? {
    path = libvirt_volume.base_image[basename(abspath(each.value.base_image_path))].path
    format = {
      type = "qcow2"
    }
  } : null
}

# Host SSH keys MUST be generated locally prior to guest deployment
# to establish trust relationships without relying on trust-on-first-use network inspection.
resource "tls_private_key" "guest_host_key" {
  for_each  = var.guest_config.all_nodes_map
  algorithm = "ED25519"
}

resource "libvirt_cloudinit_disk" "cloud_init" {

  for_each = var.guest_config.all_nodes_map
  name     = "${each.key}-cloud-init.iso"

  meta_data = yamlencode({})
  user_data = "#cloud-config\n${yamlencode({
    fqdn                 = each.key
    hostname             = each.key
    preserve_hostname    = false
    create_hostname_file = true
    manage_etc_hosts     = true
    ssh_deletekeys       = false
    timezone             = "Asia/Taipei"
    ssh_keys = {
      ed25519_private = tls_private_key.guest_host_key[each.key].private_key_openssh
      ed25519_public  = tls_private_key.guest_host_key[each.key].public_key_openssh
    }
    users = [
      {
        name                = var.credentials.username
        lock_passwd         = true
        sudo                = ["ALL=(ALL) NOPASSWD:ALL"]
        ssh_authorized_keys = [trimspace(data.local_file.ssh_public_key.content)]
      }
    ]
  })}"

  network_config = templatefile("${path.module}/templates/network_config.tftpl", {
    nat_mac                  = local.nodes_config[each.key].nat_mac
    hostonly_mac             = local.nodes_config[each.key].hostonly_mac
    hostonly_ip_cidr         = local.nodes_config[each.key].hostonly_ip_cidr
    nat_gateway              = var.libvirt_infrastructure[each.value.network_tier].network.nat.ips.address
    hostonly_gateway         = var.libvirt_infrastructure[each.value.network_tier].network.hostonly.ips.address
    mtu                      = var.libvirt_infrastructure[each.value.network_tier].network.hostonly.mtu
    static_routes            = lookup(var.static_routes, each.value.network_tier, [])
    extra_network_interfaces = local.nodes_config[each.key].extra_network_interfaces
  })
}

resource "libvirt_volume" "cloud_init_iso" {
  for_each = var.guest_config.all_nodes_map

  name = "${each.key}-cloud-init.iso"
  pool = values(var.libvirt_infrastructure)[0].storage_pool_name

  target = {
    format = {
      type = "iso"
    }
  }

  create = {
    content = {
      url = libvirt_cloudinit_disk.cloud_init[each.key].path
    }
  }

  lifecycle {
    replace_triggered_by = [libvirt_cloudinit_disk.cloud_init[each.key]]
    # The ISO path lives in tmpfs and its hash drifts after a reboot, but a volume cannot update in place.
    ignore_changes = [create]
  }
}

resource "libvirt_domain" "nodes" {

  depends_on = [
    libvirt_volume.os_disk,
    libvirt_cloudinit_disk.cloud_init,
    libvirt_volume.cloud_init_iso
  ]

  for_each = var.guest_config.all_nodes_map

  # 1. Basic Configuration (Required)
  name        = each.key
  type        = "kvm"
  vcpu        = each.value.vcpu
  memory      = each.value.ram_size
  memory_unit = "MiB"
  autostart   = false
  running     = var.start_domains

  # 2. OS Configuration
  os = {
    type = "hvm"
    arch = "x86_64"
  }

  cpu = {
    mode = "host-passthrough"
  }

  # 3. Hardware Device Configuration (Attributes)
  devices = {
    disks = concat(
      # 1. OS Disk (vda)
      [{
        device = "disk"
        target = {
          dev = "vda"
          bus = "virtio"
        }
        source = {
          volume = {
            pool   = values(var.libvirt_infrastructure)[0].storage_pool_name
            volume = libvirt_volume.os_disk[each.key].name
          }
        }
        driver = {
          type = var.os_disk_format
        }
        boot = {
          order = 1
        }
      }],

      # 2. Attached Data Volumes (vdb, vdc...)
      [for vol in each.value.attached_volumes : {
        device = "disk"
        target = {
          dev = trimprefix(vol.device_name, "/dev/")
          bus = "virtio"
        }
        source = {
          volume = {
            pool   = vol.pool
            volume = vol.volume
          }
        }
        driver = {
          type = vol.os_disk_format
        }
      }],

      # 3. Cloud-Init (sda)
      [{
        device = "cdrom"
        target = {
          dev = "sda"
          bus = "sata"
        }
        source = {
          volume = {
            pool   = values(var.libvirt_infrastructure)[0].storage_pool_name
            volume = libvirt_volume.cloud_init_iso[each.key].name
          }
        }
        boot = {
          order = 3
        }
      }]
    )

    # Network Interfaces search by network tier
    interfaces = concat(
      [
        # 1. NAT Interface
        {
          type = "network"
          source = {
            network = {
              network = var.libvirt_infrastructure[each.value.network_tier].network.nat.name_network
            }
          }
          mac = {
            address = local.nodes_config[each.key].nat_mac
          }
          model = {
            type = "virtio"
          }
        },
        # 2. HostOnly Interface
        {
          type = "network"
          source = {
            network = {
              network = var.libvirt_infrastructure[each.value.network_tier].network.hostonly.name_network
            }
          }
          mac = {
            address = local.nodes_config[each.key].hostonly_mac
          }
          model = {
            type = "virtio"
          }
        }
      ],
      # 3+. Extra Interfaces (pre-existing networks the caller names)
      [for net, iface in local.nodes_config[each.key].extra_network_interfaces : {
        type = "network"
        source = {
          network = {
            network = net
          }
        }
        mac = {
          address = iface.mac
        }
        model = {
          type = "virtio"
        }
      }]
    )

    # Other Peripherals
    consoles = [
      {
        type = "pty"
        target = {
          port = 0
          type = "serial"
        }
      },
      {
        type = "pty"
        target = {
          port = 1
          type = "virtio"
        }
      }
    ]

    graphics = [{
      vnc = {
        listen   = "0.0.0.0"
        autoport = "yes"
      }
    }]

    videos = [{
      model = {
        type    = "vga"
        vram    = 16384
        primary = "yes"
        heads   = 1
      }
    }]
  }

  # 4. Lifecycle Management: Ignore Changes for Devices
  lifecycle {
    ignore_changes = [
      devices,
    ]
  }
}
