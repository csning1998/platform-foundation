
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

data "local_file" "base_ansible_cfg" {
  filename = "${path.module}/templates/ansible.cfg.tftpl"
}

# local_file.inventory and local_file.ansible_cfg both reference this single source for the inventory path.
# Two independently computed copies of this string can diverge.
locals {
  inventory_path = "${var.ansible_config.root_path}/${var.ansible_config.inventory_file}"
}

resource "local_file" "inventory" {
  depends_on = [local_file.ansible_cfg]

  content = format(
    "---\n%s\n# Terraform Status Trigger: %s", # Render YAML opening with terraform status tracking code
    yamlencode(var.inventory_data),
    jsonencode(var.status_trigger)
  )
  filename             = local.inventory_path
  file_permission      = "0644"
  directory_permission = "0755"

  lifecycle {
    action_trigger {
      events  = [after_create, after_update]
      actions = [action.ansible_playbook_run.run_playbook]
    }
  }
}

# Roles of the caller resolve from roles_path, and the platform collection resolves from collections_path.
resource "local_file" "ansible_cfg" {
  content = replace(
    replace(
      replace(
        replace(
          data.local_file.base_ansible_cfg.content,
          "roles_path = ansible/roles",
          "roles_path = ${var.ansible_config.root_path}/roles"
        ),
        "collections_path = ansible/collections",
        "collections_path = ${var.ansible_config.root_path}/collections"
      ),
      "inventory = ansible/inventory.yaml",
      "inventory = ${local.inventory_path}"
    ),
    "ANSIBLE_RUNNER_SSH_ARGS_PLACEHOLDER",
    join(" ", compact([
      var.ansible_config.known_hosts_path != null ? "-o UserKnownHostsFile=${var.ansible_config.known_hosts_path} -o StrictHostKeyChecking=yes" : "",
      var.ansible_config.identity_key_path != null ? "-i ${var.ansible_config.identity_key_path}" : "",
    ]))
  )
  filename             = "${path.cwd}/ansible.cfg"
  file_permission      = "0644"
  directory_permission = "0755"
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
