
# Tenant ACL policy definitions map least-privilege KV and PKI paths keyed by tenant identifier.
locals {
  tenant_policy_paths = {
    for name, t in local.tenants : name => merge(
      merge([
        for kv_path in t.kv_paths : {
          "${vault_mount.kv.path}/data/${kv_path}/*" = {
            capabilities = ["create", "read", "update", "delete"]
          }
          "${vault_mount.kv.path}/metadata/${kv_path}/*" = {
            capabilities = ["create", "read", "update", "list", "delete"]
          }
        }
      ]...),
      merge([
        for kv_path in t.kv_read_paths : {
          "${vault_mount.kv.path}/data/${kv_path}"     = { capabilities = ["read"] }
          "${vault_mount.kv.path}/metadata/${kv_path}" = { capabilities = ["read"] }
        }
      ]...),
      merge([
        for pki_role in t.pki_roles : {
          "${local.downstream_vault_config.pki_mount_path}/issue/${pki_role}" = { capabilities = ["create", "update"] }
        }
      ]...)
    )
  }
}

locals {
  operator_policy_paths = {
    "${vault_mount.kv.path}/data/${local.foundation_project_code}/*" = {
      capabilities = ["create", "read", "update", "delete"]
    }
    "${vault_mount.kv.path}/metadata/${local.foundation_project_code}/*" = {
      capabilities = ["create", "read", "update", "list", "delete"]
    }
    "${vault_mount.kv.path}/delete/${local.foundation_project_code}/*"  = { capabilities = ["update"] }
    "${vault_mount.kv.path}/destroy/${local.foundation_project_code}/*" = { capabilities = ["update"] }

    "sys/mounts/${local.downstream_vault_config.pki_mount_path}" = { capabilities = ["create", "read", "update", "delete"] }
    "${local.downstream_vault_config.pki_mount_path}/*"          = { capabilities = ["create", "read", "update", "delete", "list"] }

    "sys/auth/oidc*"        = { capabilities = ["create", "read", "update", "delete", "sudo"] }
    "sys/mounts/auth/oidc*" = { capabilities = ["create", "read", "update", "delete", "sudo"] }
    "auth/oidc/*"           = { capabilities = ["create", "read", "update", "delete", "list"] }

    # Kubernetes auth mounts of the clusters of the tenant. Every mount name starts with the project code.
    "sys/auth"                                           = { capabilities = ["read"] }
    "sys/auth/${local.foundation_project_code}-*"        = { capabilities = ["create", "read", "update", "delete", "sudo"] }
    "sys/mounts/auth/${local.foundation_project_code}-*" = { capabilities = ["create", "read", "update"] }
    "auth/${local.foundation_project_code}-*"            = { capabilities = ["create", "read", "update", "delete", "list"] }

    "identity/group"            = { capabilities = ["create", "update"] }
    "identity/group/id/*"       = { capabilities = ["create", "read", "update", "delete"] }
    "identity/group-alias"      = { capabilities = ["create", "update"] }
    "identity/group-alias/id/*" = { capabilities = ["create", "read", "update", "delete"] }
    "sys/policies/acl/*"        = { capabilities = ["create", "read", "update", "delete"] }
  }
}
