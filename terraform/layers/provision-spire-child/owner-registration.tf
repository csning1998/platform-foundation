
# Every owner registers its own entries through ClusterStaticEntry, and this file declares only the bounds of that registration.
locals {
  external_owners = local.state.security_vault_downstream_tenants.downstream_vault_owners
  # The platform group MUST NOT receive the grant, since a platform component operator could register the identity of another component.
  registration_owners = sort(keys(local.external_owners))

  owner_registration = {
    name               = "spire-owner-registration"
    group_prefix       = "${local.state.platform_spire_child.spire_child_endpoints.kubernetes_operator_group}:"
    workstation_key    = "workstation_agent_id"
    server_id          = "spiffe://${local.spiffe_trust_domain}/spire/server"
    trust_domain_regex = replace(local.spiffe_trust_domain, ".", "\\.")
    login_rate         = { rate = 5, interval = 1 }
  }

  owner_roles = merge([
    for owner, o in local.external_owners : {
      for kind in ["operator", "workload"] : o[kind].role_name => {
        policy_name   = o[kind].policy_name
        spiffe_prefix = o[kind].spiffe_prefix
      }
    }
  ]...)
}

# bound_subject matches exactly, hence a glob on the sub claim binds every identity below the owner prefix.
resource "vault_jwt_auth_backend_role" "owner" {
  provider = vault.downstream
  for_each = local.owner_roles

  backend           = vault_jwt_auth_backend.spire_child.path
  role_name         = each.key
  role_type         = "jwt"
  bound_audiences   = [local.spire_child_jwt_auth.audience]
  bound_claims_type = "glob"
  bound_claims      = { sub = "${each.value.spiffe_prefix}*" }
  user_claim        = "sub"
  token_policies    = [each.value.policy_name]
  token_ttl         = 15 * 60
  token_max_ttl     = 60 * 60
}

resource "vault_quota_rate_limit" "owner" {
  provider = vault.downstream
  for_each = vault_jwt_auth_backend_role.owner

  name = "${local.spire_child_cluster_name}-${each.key}"
  # Vault stores the mount path with a trailing slash, and a path without one forces a replacement on every plan.
  path     = "auth/${vault_jwt_auth_backend.spire_child.path}/"
  role     = each.value.role_name
  rate     = local.owner_registration.login_rate.rate
  interval = local.owner_registration.login_rate.interval
}

resource "kubernetes_cluster_role_v1" "owner_registration" {
  metadata {
    name = local.owner_registration.name
  }

  rule {
    api_groups = ["spire.spiffe.io"]
    resources  = ["clusterstaticentries"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "owner_registration" {
  metadata {
    name = local.owner_registration.name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.owner_registration.metadata[0].name
  }

  dynamic "subject" {
    for_each = local.registration_owners
    content {
      api_group = "rbac.authorization.k8s.io"
      kind      = "Group"
      name      = "${local.owner_registration.group_prefix}${subject.value}"
    }
  }
}

# The workstation agent attests with a join token, and its ID changes on every attestation.
# The join token is spent once the agent attests, hence the ID may sit in plain state.
data "vault_kv_secret_v2" "workstation_join_token" {
  provider   = vault.downstream
  depends_on = [module.workstation_child_agent]

  mount = "secret"
  name  = "${local.workstation_agent_extra_vars.spire_child_join_token_kv_path}/${local.workstation_cluster_name}/workstation"
}

resource "kubernetes_config_map_v1" "owner_registration" {
  metadata {
    name      = local.owner_registration.name
    namespace = kubernetes_namespace_v1.spire_server.metadata[0].name
  }

  data = {
    (local.owner_registration.workstation_key) = "spiffe://${local.spiffe_trust_domain}/spire/agent/join_token/${nonsensitive(data.vault_kv_secret_v2.workstation_join_token.data["join_token"])}"
  }
}

# The policy derives the owner from the group of the caller and confines the entries of that owner to its own prefix.
# A node alias, whose parent is the server, MUST select only nodes with the owner CN, which only the owner can issue.
resource "kubernetes_manifest" "owner_registration_policy" {
  depends_on = [helm_release.spire_crds]

  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicy"
    metadata   = { name = local.owner_registration.name }
    spec = {
      failurePolicy = "Fail"
      paramKind     = { apiVersion = "v1", kind = "ConfigMap" }
      matchConstraints = {
        resourceRules = [{
          apiGroups   = ["spire.spiffe.io"]
          apiVersions = ["*"]
          operations  = ["CREATE", "UPDATE", "DELETE"]
          resources   = ["clusterstaticentries"]
        }]
      }
      matchConditions = [{
        name       = "owner-operator"
        expression = "request.userInfo.groups.exists(g, g.startsWith('${local.owner_registration.group_prefix}'))"
      }]
      variables = [
        {
          name       = "owner"
          expression = "request.userInfo.groups.filter(g, g.startsWith('${local.owner_registration.group_prefix}'))[0].split(':')[1]"
        },
        {
          name       = "ownerID"
          expression = "r'^spiffe://${local.owner_registration.trust_domain_regex}/' + variables.owner + r'(/[a-z0-9_-][a-z0-9._-]*)+$'"
        },
      ]
      validations = [
        {
          expression = "variables.owner.matches(r'^[a-z0-9]+(-[a-z0-9]+)*$')"
          message    = "the owner code of the caller MUST be lowercase alphanumeric segments joined by hyphens"
        },
        {
          expression = "request.operation == 'DELETE' || object.spec.spiffeID.matches(variables.ownerID)"
          message    = "spiffeID MUST stay below the owner prefix"
        },
        {
          expression = "request.operation == 'CREATE' || oldObject.spec.spiffeID.matches(variables.ownerID)"
          message    = "an owner MUST NOT change or delete the entries of another owner"
        },
        {
          expression = join(" || ", [
            "request.operation == 'DELETE'",
            "object.spec.parentID == params.data['${local.owner_registration.workstation_key}']",
            "object.spec.parentID.matches(variables.ownerID)",
            "(object.spec.parentID == '${local.owner_registration.server_id}' && size(object.spec.selectors) > 0 && object.spec.selectors.all(s, s.matches(r'^x509pop:subject:cn:' + variables.owner + r'-[a-z0-9.-]+$')))",
          ])
          message = "parentID MUST be the workstation agent, a node alias of the owner, or the server for a node alias selecting owner CNs"
        },
        {
          expression = "request.operation == 'DELETE' || ((!has(object.spec.admin) || !object.spec.admin) && (!has(object.spec.downstream) || !object.spec.downstream))"
          message    = "admin and downstream MUST be false"
        },
        {
          expression = "request.operation == 'DELETE' || !has(object.spec.dnsNames) || size(object.spec.dnsNames) == 0"
          message    = "dnsNames MUST be empty, since an X509-SVID with a platform DNS name would pass as that service"
        },
      ]
    }
  }
}

resource "kubernetes_manifest" "owner_registration_binding" {
  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicyBinding"
    metadata   = { name = local.owner_registration.name }
    spec = {
      policyName        = kubernetes_manifest.owner_registration_policy.manifest.metadata.name
      validationActions = ["Deny"]
      paramRef = {
        name                    = kubernetes_config_map_v1.owner_registration.metadata[0].name
        namespace               = kubernetes_config_map_v1.owner_registration.metadata[0].namespace
        parameterNotFoundAction = "Deny"
      }
    }
  }
}
