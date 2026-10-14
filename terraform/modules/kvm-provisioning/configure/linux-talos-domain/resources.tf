
resource "libvirt_network" "nat_networks" {
  for_each = var.create_networks ? var.network_infrastructure : {}

  name      = each.value.nat.name
  autostart = true
  bridge    = { name = each.value.nat.bridge_name }
  forward   = { mode = "nat" }

  ips = [{
    address = each.value.nat.gateway
    prefix  = each.value.nat.prefix
    dhcp = {
      ranges = each.value.nat.dhcp != null ? [{
        start = each.value.nat.dhcp.start
        end   = each.value.nat.dhcp.end
      }] : []
    }
  }]
}

resource "libvirt_network" "hostonly_networks" {
  for_each = var.create_networks ? var.network_infrastructure : {}

  name      = each.value.hostonly.name
  autostart = true
  bridge    = { name = each.value.hostonly.bridge_name }
  forward   = { mode = "route" }

  ips = [{
    address = each.value.hostonly.gateway
    prefix  = each.value.hostonly.prefix
  }]
}

resource "libvirt_network" "service_networks" {
  for_each = var.create_networks ? { for seg in var.talos_cluster_service_segments : seg.name => seg } : {}

  name      = each.value.name
  autostart = true
  bridge    = { name = each.value.bridge_name }
  forward   = { mode = "route" }

  ips = [{
    address = cidrhost(each.value.cidr, 1)
    prefix  = tonumber(split("/", each.value.cidr)[1])
  }]
}

# Shared boot media volume. Talos defers disk partitioning and OS installation until network
# machine configuration deployment, maintaining this volume attached as a read-only CD-ROM device.
resource "libvirt_volume" "talos_iso" {
  name = "talos-metal-amd64-${basename(dirname(var.talos_iso_path))}.iso"
  pool = var.talos_cluster_vm_config.storage_pool_name

  target = {
    format = {
      type = "iso"
    }
  }

  create = {
    content = {
      url = abspath(var.talos_iso_path)
    }
  }
}

# Unformatted OS target volume. Talos partitions and installs the operating system directly
# upon machine configuration receipt, bypassing base image and cloud-init dependencies.
resource "libvirt_volume" "os_disk" {
  for_each = var.talos_cluster_vm_config.nodes

  pool     = var.talos_cluster_vm_config.storage_pool_name
  name     = "${each.key}-os.${var.os_disk_format}"
  capacity = each.value.os_disk_capacity_gib * 1024 * 1024 * 1024

  target = {
    format = {
      type = var.os_disk_format
    }
  }
}

resource "libvirt_domain" "nodes" {
  depends_on = [
    libvirt_network.service_networks,
    libvirt_network.nat_networks,
    libvirt_network.hostonly_networks,
    libvirt_volume.os_disk,
    libvirt_volume.talos_iso,
  ]

  for_each = var.talos_cluster_vm_config.nodes

  name        = each.key
  type        = "kvm"
  vcpu        = each.value.vcpu
  memory      = each.value.ram
  memory_unit = "MiB"
  autostart   = false
  running     = true

  os  = { type = "hvm", arch = "x86_64" }
  cpu = { mode = "host-passthrough" }

  # Per-cluster pinning cannot see the cores of other clusters, hence the caller assigns host CPUs explicitly.
  cpu_tune = each.value.cpu_pin == null ? null : {
    vcpu_pin = [for i, cpu in each.value.cpu_pin : { vcpu = i, cpu_set = tostring(cpu) }]
  }

  devices = {
    disks = concat([
      # Primary boot device. Unpartitioned volumes lack bootable sectors, causing firmware boot
      # sequence fallthrough to secondary ISO media prior to OS installation.
      {
        device = "disk"
        target = { dev = "vda", bus = "virtio" }
        driver = { type = var.os_disk_format }
        boot   = { order = 1 }
        source = {
          volume = {
            pool   = var.talos_cluster_vm_config.storage_pool_name
            volume = libvirt_volume.os_disk[each.key].name
          }
        }
      },
      # Secondary boot device for installation ISO. Kernel parameter `talos.halt_if_installed`
      # halts execution on subsequent boots to prevent redundant OS re-installation.
      {
        device = "cdrom"
        target = { dev = "sda", bus = "sata" }
        boot   = { order = 2 }
        source = {
          volume = {
            pool   = var.talos_cluster_vm_config.storage_pool_name
            volume = libvirt_volume.talos_iso.name
          }
        }
      }
      ],
      # Data disks follow the OS disk in declaration order. The guest names the devices vdb, vdc, and the following letters.
      [
        for idx, vol in each.value.attached_volumes : {
          device = "disk"
          target = { dev = "vd${substr("bcdefghijklmnopqrstuvwxyz", idx, 1)}", bus = "virtio" }
          driver = { type = vol.os_disk_format }
          source = {
            volume = {
              pool   = vol.pool
              volume = vol.volume
            }
          }
        }
    ])

    interfaces = [
      for idx, iface in each.value.interfaces : {
        type        = "network"
        mac         = { address = iface.mac }
        model       = { type = "virtio" }
        source      = { network = { network = iface.network_name } }
        wait_for_ip = idx == 0 ? { timeout = 300, source = "lease" } : null
        # Network readiness validation MUST monitor DHCP lease acquisition exclusively on primary NAT interfaces.
      }
    ]

    consoles = [
      {
        type   = "pty"
        target = { port = 0, type = "serial" }
      },
      {
        type   = "pty"
        target = { port = 1, type = "virtio" }
      }
    ]

    # The console listens on the loopback interface of the hypervisor.
    # Remote console access MUST pass through an SSH tunnel to the hypervisor.
    graphics = [{
      vnc = { listen = "127.0.0.1", autoport = "yes" }
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

  # Lifecycle management MUST ignore disk and interface attribute drift
  # because the Libvirt provider computes false difference states following initial guest bootstrap.
  lifecycle {
    ignore_changes = [devices]
  }
}
