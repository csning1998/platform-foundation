
terraform {
  required_version = ">= 1.14.0"
  required_providers {
    ansible = {
      source  = "ansible/ansible"
      version = "~> 1.5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9.0"
    }
  }
}

# Connection variables live in the inventory, since instances of this module in one layer share the working directory.
locals {
  connection_vars = merge(
    { ansible_pipelining = true },
    var.ansible_config.identity_key_path != null ? { ansible_ssh_private_key_file = var.ansible_config.identity_key_path } : {},
    var.ansible_config.known_hosts_path != null ? {
      ansible_ssh_common_args = "-o UserKnownHostsFile=${var.ansible_config.known_hosts_path} -o StrictHostKeyChecking=yes"
    } : {},
  )

  inventory_data = merge(var.inventory_data, {
    all = merge(var.inventory_data.all, {
      vars = merge(local.connection_vars, try(var.inventory_data.all.vars, {}))
    })
  })
}

resource "local_file" "inventory" {
  content = format(
    "---\n%s\n# Terraform Status Trigger: %s", # Render YAML opening with terraform status tracking code
    yamlencode(local.inventory_data),
    jsonencode(var.status_trigger)
  )
  filename             = "${var.ansible_config.root_path}/${var.ansible_config.inventory_file}"
  file_permission      = "0644"
  directory_permission = "0755"

  lifecycle {
    action_trigger {
      events  = [after_create, after_update]
      actions = [action.ansible_playbook_run.run_playbook]
    }
  }
}

action "ansible_playbook_run" "run_playbook" {
  config {
    playbooks               = var.playbook_paths
    inventory_files         = [caller.filename]
    extra_vars              = var.extra_vars
    verbosity               = var.ansible_config.verbosity
    ansible_playbook_binary = "ansible-playbook"
    tags                    = var.ansible_tags
    skip_tags               = var.ansible_skip_tags
  }
}
