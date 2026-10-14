
# An external owner registers its own operators and workloads, bounded by its owner prefix, its services, and its cidr_index range.
locals {
  _external_owners = {
    "opgitlab" = { services = ["gitlab", "harbor"], cidr_index = { first = 140, last = 153 } }
  }
}

locals {
  network_baseline    = local.state.foundation_libvirt_resources.foundation_network_global.network_baseline
  node_pki_mount_path = "pki-spire-node"

  external_owners = {
    for owner, o in local._external_owners : owner => {
      services = o.services
      cidr_blocks = [
        for index in range(o.cidr_index.first, o.cidr_index.last + 1) :
        cidrsubnet(local.network_baseline.cidr_block, local.network_baseline.cidr_subnet_bits, index)
      ]
      nat_cidr_blocks = [
        for index in range(o.cidr_index.first, o.cidr_index.last + 1) :
        cidrsubnet(local.network_baseline.cidr_block, local.network_baseline.cidr_subnet_bits, index - local.network_baseline.cidr_nat_offset)
      ]
      operator_role        = "${owner}-terraform-operator"
      workload_role        = "${owner}-workload"
      pki_mount_path       = "pki-owner-${owner}"
      registration_kv_path = "${owner}/spire/registration"
    }
  }
}

# The owner policies key on the owner code as a path prefix, hence the checks below keep codes, services, and networks exclusive.
locals {
  owner_codes = concat([local.foundation_project_code], keys(local._external_owners))
  owner_code_conflicts = concat(
    [for code in distinct(local.owner_codes) : code if length([for c in local.owner_codes : c if c == code]) > 1],
    flatten([for a in local.owner_codes : [for b in local.owner_codes : "${a} prefixes ${b}" if a != b && startswith(b, "${a}-")]]),
  )

  all_services = concat(
    keys(local.state.foundation_libvirt_resources.foundation_topology.identity),
    flatten([for o in local.external_owners : o.services]),
  )
  service_conflicts = [for s in distinct(local.all_services) : s if length([for x in local.all_services : x if x == s]) > 1]

  all_cidr_blocks = concat(
    distinct(flatten([
      for service, components in local.state.foundation_libvirt_resources.foundation_topology.network : [
        for component, network in components : [network.cidr_block, network.nat_cidr_block]
      ]
    ])),
    flatten([for o in local.external_owners : concat(o.cidr_blocks, o.nat_cidr_blocks)]),
  )
  cidr_block_conflicts = [for c in distinct(local.all_cidr_blocks) : c if length([for x in local.all_cidr_blocks : x if x == c]) > 1]
}

resource "terraform_data" "external_owners_validation" {
  input = keys(local._external_owners)

  lifecycle {
    precondition {
      condition     = length(local.owner_code_conflicts) == 0
      error_message = "Owner codes MUST be unique and MUST NOT prefix one another: ${join(", ", local.owner_code_conflicts)}."
    }
    precondition {
      condition     = length(local.service_conflicts) == 0
      error_message = "Every service name MUST belong to exactly one owner: ${join(", ", local.service_conflicts)}."
    }
    precondition {
      condition     = length(local.cidr_block_conflicts) == 0
      error_message = "Every network MUST belong to exactly one owner: ${join(", ", local.cidr_block_conflicts)}."
    }
  }
}

locals {
  external_owner_policy_paths = {
    for owner, o in local.external_owners : owner => {
      operator = {
        "sys/internal/ui/mounts/${vault_mount.kv.path}/*" = { capabilities = ["read"] }

        "${vault_mount.kv.path}/data/${owner}/*"     = { capabilities = ["create", "read", "update", "delete", "patch"] }
        "${vault_mount.kv.path}/metadata/${owner}"   = { capabilities = ["list"] }
        "${vault_mount.kv.path}/metadata/${owner}/*" = { capabilities = ["create", "read", "update", "list", "delete"] }

        "sys/auth"                   = { capabilities = ["read"] }
        "sys/auth/${owner}-*"        = { capabilities = ["create", "read", "update", "delete", "sudo"] }
        "sys/mounts/auth/${owner}-*" = { capabilities = ["create", "read", "update"] }
        "auth/${owner}-*" = {
          capabilities = ["create", "read", "update", "delete", "list"]
          allowed_parameters = {
            "token_policies" = ["default", o.workload_role]
            "policies"       = ["default", o.workload_role]
            "*"              = []
          }
        }

        "${o.pki_mount_path}/issue/${owner}"          = { capabilities = ["create", "update"] }
        "${local.node_pki_mount_path}/issue/${owner}" = { capabilities = ["create", "update"] }
      }

      workload = {
        "${vault_mount.kv.path}/data/${owner}/*"     = { capabilities = ["read"] }
        "${vault_mount.kv.path}/metadata/${owner}/*" = { capabilities = ["read"] }
        "${o.pki_mount_path}/issue/${owner}"         = { capabilities = ["create", "update"] }
      }
    }
  }
}

resource "vault_policy" "external_owner_operator" {
  provider = vault.downstream
  for_each = local.external_owners

  name   = each.value.operator_role
  policy = jsonencode({ path = local.external_owner_policy_paths[each.key].operator })
}

resource "vault_policy" "external_owner_workload" {
  provider = vault.downstream
  for_each = local.external_owners

  name   = each.value.workload_role
  policy = jsonencode({ path = local.external_owner_policy_paths[each.key].workload })
}
