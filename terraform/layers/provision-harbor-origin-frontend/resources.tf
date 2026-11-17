
resource "harbor_registry" "proxy_registries" {
  for_each      = local.proxy_caches
  name          = each.value.registry_name
  endpoint_url  = each.value.endpoint_url
  provider_name = each.value.provider_name
}

# The proxy caches serve public upstream images. Anonymous pulls exclude registry credentials from the Talos machine configuration.
resource "harbor_project" "proxy_projects" {
  for_each      = local.proxy_caches
  name          = each.value.project_name
  public        = true
  force_destroy = true
  registry_id   = harbor_registry.proxy_registries[each.key].registry_id
}

resource "harbor_project" "proxy_oci" {
  for_each      = local.proxy_oci
  name          = each.value.name
  public        = false
  force_destroy = true
}

resource "harbor_robot_account" "helm_puller" {
  name        = "helm-puller"
  description = "System level Robot account for Helm Provider to pull from local and proxy caches"
  level       = "system"

  secret_wo         = ephemeral.random_password.robot_secret["helm_puller"].result
  secret_wo_version = local.robot_secret_version

  permissions {
    kind      = "project"
    namespace = harbor_project.proxy_oci["helm_charts"].name
    access {
      action   = "pull"
      resource = "repository"
    }
  }

  dynamic "permissions" {
    for_each = harbor_project.proxy_projects
    content {
      kind      = "project"
      namespace = permissions.value.name
      access {
        action   = "pull"
        resource = "repository"
      }
    }
  }

  # Replacing the Vault secret triggers recreation of the robot account to prevent authentication drift.
  lifecycle {
    replace_triggered_by = [vault_kv_secret_v2.robot_helm_creds]
  }
}

resource "harbor_robot_account" "helm_pusher" {
  name        = "helm-pusher"
  description = "Robot account for pushing Helm charts to OCI registry"
  level       = "project"

  secret_wo         = ephemeral.random_password.robot_secret["helm_pusher"].result
  secret_wo_version = local.robot_secret_version
  permissions {
    kind      = "project"
    namespace = harbor_project.proxy_oci["helm_charts"].name
    access {
      action   = "push"
      resource = "repository"
    }
    access {
      action   = "pull"
      resource = "repository"
    }
  }

  # Replacing the Vault secret triggers recreation of the robot account to prevent authentication drift.
  lifecycle {
    replace_triggered_by = [vault_kv_secret_v2.robot_helm_creds]
  }
}

# Untracked write-only credentials require a unified secret resource to maintain rotation parity between Harbor and Vault.
resource "vault_kv_secret_v2" "robot_helm_creds" {
  provider = vault.downstream
  mount    = "secret"
  name     = local.downstream_kv_paths["harbor-origin"]["frontend"].robot
  data_json_wo = jsonencode({
    username_puller = "robot$helm-puller"
    password_puller = ephemeral.random_password.robot_secret["helm_puller"].result
    username_pusher = format("robot$%s+helm-pusher", harbor_project.proxy_oci["helm_charts"].name)
    password_pusher = ephemeral.random_password.robot_secret["helm_pusher"].result
  })
  data_json_wo_version = local.robot_secret_version
}
