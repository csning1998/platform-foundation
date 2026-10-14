
# Vault OSS bounds neither the content of a policy nor the policies of an auth role, hence a component operator does not write any policy.
# This layer declares every workload policy of a component, and the operator assigns only those names through allowed_parameters.
locals {
  # Cross-component KV grants and in-cluster workloads of each component, keyed as the component operators.
  component_workloads = {
    "cilium" = {
      kv_read_paths             = [local.foundation_kv_paths["harbor-origin"]["frontend"].robot]
      kv_write_folders          = []
      cluster_issuer            = true
      external_secrets_kv_paths = ["${local.foundation_kv_paths["cilium"]["hubble"].addon}-hubble-ui"]
    }
    "keycloak" = {
      kv_read_paths             = [local.foundation_kv_paths["harbor-origin"]["frontend"].robot]
      kv_write_folders          = ["${local.foundation_project_code}/keycloak/oidc/clients"]
      cluster_issuer            = true
      external_secrets_kv_paths = [local.foundation_kv_paths["keycloak"]["frontend"].app]
    }
    "harbor-origin" = {
      kv_read_paths             = ["${local.foundation_project_code}/keycloak/oidc/clients/harbor-origin-frontend"]
      kv_write_folders          = []
      cluster_issuer            = false
      external_secrets_kv_paths = []
    }
    "spire-child" = {
      kv_read_paths             = []
      kv_write_folders          = []
      cluster_issuer            = false
      external_secrets_kv_paths = []
    }
  }

  child_tenants = { for name, t in local.tenants : name => t if t.issuer == "child" }

  # The JWT mount of the SPIRE Child carries the cluster name of the Child, which the owned auth scope of the Child operator covers.
  spire_child_jwt_auth = {
    mount_path = "${local.state.foundation_libvirt_resources.foundation_topology.identity["spire"]["child"].cluster_name}-jwt-svid-provider"
    audience   = local.state.foundation_libvirt_resources.foundation_topology.identity["vault-downstream"]["frontend"].cluster_name
  }

  workload_policies = merge(
    {
      for key, w in local.component_workloads : "${local.component_operators[key].cluster_name}-cluster-issuer" => {
        "${local.downstream_vault_config.pki_mount_path}/sign/${local.component_operators[key].cluster_name}"  = { capabilities = ["create", "update"] }
        "${local.downstream_vault_config.pki_mount_path}/issue/${local.component_operators[key].cluster_name}" = { capabilities = ["create", "update"] }
      } if w.cluster_issuer
    },
    {
      for key, w in local.component_workloads : "${local.component_operators[key].cluster_name}-external-secrets" => merge([
        for kv_path in w.external_secrets_kv_paths : {
          "${vault_mount.kv.path}/data/${kv_path}"     = { capabilities = ["read"] }
          "${vault_mount.kv.path}/metadata/${kv_path}" = { capabilities = ["read"] }
        }
      ]...) if length(w.external_secrets_kv_paths) > 0
    },
  )

  # The owned auth mounts of an operator admit default and the workload policies which name the cluster of the operator.
  component_assignable = {
    for key, operator in local.component_operators : key => {
      owned = concat(
        ["default"],
        [for suffix in ["cluster-issuer", "external-secrets"] : "${operator.cluster_name}-${suffix}" if contains(keys(local.workload_policies), "${operator.cluster_name}-${suffix}")],
        key == "spire-child" ? sort(keys(local.child_tenants)) : [],
        key == "spire-child" ? sort([for operator in local.terraform_operators : operator.role_name if operator.server == "child"]) : [],
        key == "spire-child" ? sort(flatten([for o in local.external_owners : [o.operator_role, o.workload_role]])) : [],
      )
    }
  }

  # The join tokens stay below the cluster of the component on both SPIRE servers, and the Child operator also records the workstation agent.
  component_operator_paths = {
    for key, operator in local.component_operators : key => merge(
      {
        "sys/internal/ui/mounts/${vault_mount.kv.path}/*" = { capabilities = ["read"] }

        "${vault_mount.kv.path}/data/${local.component_kv_paths[key]}/*"     = { capabilities = ["create", "read", "update", "delete", "patch"] }
        "${vault_mount.kv.path}/metadata/${local.component_kv_paths[key]}"   = { capabilities = ["list"] }
        "${vault_mount.kv.path}/metadata/${local.component_kv_paths[key]}/*" = { capabilities = ["create", "read", "update", "list", "delete"] }

        "sys/auth"                                   = { capabilities = ["read"] }
        "sys/auth/${operator.cluster_name}-*"        = { capabilities = ["create", "read", "update", "delete", "sudo"] }
        "sys/mounts/auth/${operator.cluster_name}-*" = { capabilities = ["create", "read", "update"] }
        "auth/${operator.cluster_name}-*" = {
          capabilities = ["create", "read", "update", "delete", "list"]
          allowed_parameters = {
            "token_policies" = local.component_assignable[key].owned
            "policies"       = local.component_assignable[key].owned
            "*"              = []
          }
        }

        "sys/mounts/${local.downstream_vault_config.pki_mount_path}"                     = { capabilities = ["read"] }
        "${local.downstream_vault_config.pki_mount_path}/roles/${operator.cluster_name}" = { capabilities = ["create", "read", "update", "delete"] }
        "${local.downstream_vault_config.pki_mount_path}/issue/${operator.cluster_name}" = { capabilities = ["create", "update"] }

        "${vault_mount.kv.path}/data/${local.foundation_kv_paths["spire"]["child"].registrar}" = {
          capabilities = key == "spire-child" ? ["create", "read", "update", "delete", "patch"] : ["read"]
        }
      },
      merge([
        for kv_path in local.component_workloads[key].kv_read_paths : {
          "${vault_mount.kv.path}/data/${kv_path}" = { capabilities = ["read"] }
        }
      ]...),
      merge([
        for folder in local.component_workloads[key].kv_write_folders : {
          "${vault_mount.kv.path}/data/${folder}/*"     = { capabilities = ["create", "read", "update", "delete", "patch"] }
          "${vault_mount.kv.path}/metadata/${folder}/*" = { capabilities = ["create", "read", "update", "list", "delete"] }
        }
      ]...),
      merge([
        for server in ["parent", "child"] : merge([
          for cluster in concat([operator.cluster_name], key == "spire-child" && server == "child" ? [local.workstation_cluster_name] : []) : {
            "${vault_mount.kv.path}/data/${local.foundation_kv_paths["spire"][server].join_token}/${cluster}/*"     = { capabilities = ["create", "read", "update"] }
            "${vault_mount.kv.path}/metadata/${local.foundation_kv_paths["spire"][server].join_token}/${cluster}/*" = { capabilities = ["create", "read", "update", "list"] }
          }
        ]...)
      ]...),
      # provision-spire-child writes the kubeconfig of the registration ServiceAccount of every external owner.
      merge([
        for o in local.external_owners : {
          "${vault_mount.kv.path}/data/${o.registration_kv_path}"     = { capabilities = ["create", "read", "update", "delete", "patch"] }
          "${vault_mount.kv.path}/metadata/${o.registration_kv_path}" = { capabilities = ["read", "update", "delete"] }
        } if key == "spire-child"
      ]...),
    )
  }

  component_kv_paths = {
    for key, operator in local.component_operators : key => local.state.foundation_libvirt_resources.foundation_vault_path.credential_paths[operator.service][operator.component]
  }
}

module "spire_child_operator_identity" {
  source = "../../modules/kvm-provisioning/helpers/terraform-operator-identity"

  operator_identity_config = {
    server            = "child"
    targets           = local._spire_child_operator_targets
    topology_identity = local.state.foundation_libvirt_resources.foundation_topology.identity
  }
}

check "spire_child_operator_targets_exist" {
  assert {
    condition     = length(module.spire_child_operator_identity.operator_identity.missing_targets) == 0
    error_message = "_spire_child_operator_targets names a component which foundation-libvirt-resources lacks: ${join(", ", module.spire_child_operator_identity.operator_identity.missing_targets)}."
  }
}

resource "terraform_data" "component_workloads_validation" {
  input = keys(local.component_workloads)

  lifecycle {
    precondition {
      condition     = toset(keys(local.component_workloads)) == toset(keys(local.component_operators))
      error_message = "component_workloads MUST declare exactly the component operators of provision-spire-parent: ${join(", ", sort(keys(local.component_operators)))}."
    }
  }
}

resource "vault_policy" "workload" {
  provider = vault.downstream
  for_each = local.workload_policies

  name   = each.key
  policy = jsonencode({ path = each.value })
}

resource "vault_policy" "component_operator" {
  provider = vault.downstream
  for_each = local.component_operators

  name   = each.value.role_name
  policy = jsonencode({ path = local.component_operator_paths[each.key] })
}

locals {
  # provision-spire-child creates the roles of the Child operators under the same names.
  operator_role_names = merge(
    { "vault-downstream" = vault_jwt_auth_backend_role.operator.role_name },
    { for key, role in vault_jwt_auth_backend_role.component_operator : key => role.role_name },
    { for key, operator in local.terraform_operators : key => operator.role_name if operator.server == "child" },
  )
}

# The roles of the operators on the SPIRE Child live on the Child mount, which provision-spire-child creates.
resource "vault_jwt_auth_backend_role" "component_operator" {
  provider = vault.downstream
  for_each = { for key, operator in local.component_operators : key => operator if operator.server == "parent" }

  backend         = local.jwt_auth.parent.mount_path
  role_name       = each.value.role_name
  role_type       = "jwt"
  bound_audiences = [local.jwt_auth.parent.audience]
  bound_subject   = "spiffe://${local.spiffe_trust_domain}${each.value.spiffe_path}"
  user_claim      = "sub"

  token_policies = [vault_policy.component_operator[each.key].name]
  token_ttl      = 15 * 60
  token_max_ttl  = 60 * 60
}
