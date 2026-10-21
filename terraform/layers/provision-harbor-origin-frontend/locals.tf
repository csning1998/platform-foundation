
# GitLab HTTP backend base URL. Authentication credentials must be supplied via
# `TF_HTTP_USERNAME` and `TF_HTTP_PASSWORD` environment variables.
locals {
  _state_base_platform_foundation = "https://gitlab.com/api/v4/projects/84608830/terraform/state"
}

locals {
  state = {
    security_vault_downstream_tenants = data.terraform_remote_state.security_vault_downstream_tenants.outputs
    platform_harbor_origin_frontend   = data.terraform_remote_state.platform_harbor_origin_frontend.outputs
  }
}

# The operator of this component logs in to the Downstream Vault with the JWT-SVID of the SPIRE Parent.
locals {
  terraform_operator_subject = { service = "harbor-origin", component = "frontend" }
  terraform_operator         = local.state.security_vault_downstream_tenants.downstream_vault_operators[local.terraform_operator_subject.service][local.terraform_operator_subject.component]
  downstream_vault_endpoint  = "https://${local.state.security_vault_downstream_tenants.downstream_vault_service_vip}:443"
  downstream_kv_paths        = local.state.security_vault_downstream_tenants.foundation_vault_path.kv_paths
}

locals {
  # Terraform chooses both robot secrets, which reach Harbor and the Downstream Vault through write-only arguments alone.
  # Incrementing robot_secret_version rotates both secrets in one apply.
  robot_secret_version = 2
}

locals {
  proxy_oci = {
    helm_charts = {
      name = "helm-charts"
    }
  }

  proxy_caches = {
    docker_hub = {
      upstream_domain = "docker.io"
      registry_name   = "hub.docker.com"
      endpoint_url    = "https://hub.docker.com"
      provider_name   = "docker-hub"
      project_name    = "docker-proxy"
    }
    k8s_io = {
      upstream_domain = "registry.k8s.io"
      registry_name   = "registry.k8s.io"
      endpoint_url    = "https://registry.k8s.io"
      provider_name   = "docker-registry"
      project_name    = "k8s-proxy"
    }
    quay_io = {
      upstream_domain = "quay.io"
      registry_name   = "quay.io"
      endpoint_url    = "https://quay.io"
      provider_name   = "docker-registry"
      project_name    = "quay-proxy"
    }
    gitlab_com = {
      upstream_domain = "registry.gitlab.com"
      registry_name   = "registry.gitlab.com"
      endpoint_url    = "https://registry.gitlab.com"
      provider_name   = "docker-registry"
      project_name    = "gitlab-proxy"
    }
    gcr_io = {
      upstream_domain = "gcr.io"
      registry_name   = "gcr.io"
      endpoint_url    = "https://gcr.io"
      provider_name   = "docker-registry"
      project_name    = "gcr-proxy"
    }
    ghcr_io = {
      upstream_domain = "ghcr.io"
      registry_name   = "ghcr.io"
      endpoint_url    = "https://ghcr.io"
      provider_name   = "docker-registry"
      project_name    = "ghcr-proxy"
    }
  }
}

locals {
  ansible_extra_vars = {
    harbor_robot_user      = harbor_robot_account.helm_pusher.full_name
    harbor_registry        = local.state.platform_harbor_origin_frontend.harbor_endpoint.fqdn
    harbor_project         = local.proxy_oci["helm_charts"].name
    vault_endpoint         = local.downstream_vault_endpoint
    vault_ca_cert_path     = local.state.security_vault_downstream_tenants.downstream_vault_ca_cert_path
    vault_operator_wrapper = local.terraform_operator.wrapper_name
    vault_operator_role    = local.terraform_operator.role_name
    vault_operator_mount   = local.terraform_operator.auth_mount
    harbor_robot_kv_path   = local.downstream_kv_paths["harbor-origin"]["frontend"].robot
  }

  ansible_config = {
    root_path      = abspath("${path.root}/../../../ansible")
    inventory_file = "inventory-provision-harbor-origin-frontend.yaml"
  }

  # Transforms the infra-* inventory structure into a dedicated group for the business logic of this layer
  inventory_data = {
    all = {
      children = {
        harbor_origin_oci = {
          hosts = {
            for k, v in local.state.platform_harbor_origin_frontend.generic_cluster.ansible_inventory.data.all.children.primary.hosts : k => merge(v, {
              node_role = "harbor_origin_oci"
            })
          }
        }
      }
    }
  }
}
