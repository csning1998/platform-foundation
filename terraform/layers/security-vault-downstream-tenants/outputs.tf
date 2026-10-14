
output "downstream_tenants" {
  description = "Downstream Vault connection parameters, the SPIRE Parent JWT auth backend, and the login coordinates of every tenant workload on the Parent or the Child mount."
  value = {
    endpoint     = local.downstream_vault_config.endpoint
    ca_cert_path = local.downstream_vault_config.ca_cert_path
    auth_mount   = local.jwt_auth.parent.mount_path
    audience     = local.jwt_auth.parent.audience
    kv_mount     = vault_mount.kv.path
    tenant_operator = {
      auth_mount = local.jwt_auth.parent.mount_path
      role_name  = vault_jwt_auth_backend_role.operator.role_name
      audience   = local.jwt_auth.parent.audience
    }
    role_spiffe_id = { for name, t in local.tenants : name => t.spiffe_id }
    tenant_login = {
      for name, t in local.tenants : name => {
        auth_mount = t.issuer == "parent" ? local.jwt_auth.parent.mount_path : local.spire_child_jwt_auth.mount_path
        role_name  = name
        audience   = t.issuer == "parent" ? local.jwt_auth.parent.audience : local.spire_child_jwt_auth.audience
      }
    }
  }
}

output "downstream_vault_service_vip" {
  description = "Service VIP of downstream Vault cluster retrieved from platform state."
  value       = local.state.platform_vault_downstream_frontend.vault_endpoint.service_vip
}

output "downstream_vault_endpoint" {
  description = "Downstream Vault API endpoint URL."
  value       = local.downstream_vault_config.endpoint
}

output "foundation_pki" {
  description = "Pass-through of foundation PKI configuration for downstream TLS verification."
  value       = local.state.foundation_libvirt_resources.foundation_pki
}

output "foundation_vault_path" {
  description = "Pass-through of foundation Vault KV secret paths for consumer layers."
  value       = local.state.foundation_libvirt_resources.foundation_vault_path
}

output "downstream_vault_ca_cert_path" {
  description = "Filesystem path to the CA certificate bundle validating downstream Vault listener TLS."
  value       = local.downstream_vault_config.ca_cert_path
}

output "downstream_vault_operators" {
  description = "Login coordinates of every local Terraform operator, keyed by catalog service and component as each layer declares terraform_operator_subject: the auth mount, the role, the audience, the JWT-SVID wrapper, the cluster name, the workload policies which the operator assigns on its Kubernetes auth mount, and the Vault instance, KV mount, and KV path of the cluster-config leaf. The vault-downstream operator administers the Downstream Vault and carries null workload policies."
  value = {
    for service in distinct([for operator in local.terraform_operators : operator.service]) : service => {
      for key, operator in local.terraform_operators : operator.component => {
        auth_mount   = operator.server == "child" ? local.spire_child_jwt_auth.mount_path : local.jwt_auth.parent.mount_path
        role_name    = local.operator_role_names[key]
        audience     = operator.server == "child" ? local.spire_child_jwt_auth.audience : local.jwt_auth.parent.audience
        wrapper_name = operator.wrapper_name
        cluster_name = operator.cluster_name
        # The workload policies which this layer declares for the cluster, null when the component has none.
        cluster_issuer_policy   = contains(keys(local.workload_policies), "${operator.cluster_name}-cluster-issuer") ? vault_policy.workload["${operator.cluster_name}-cluster-issuer"].name : null
        external_secrets_policy = contains(keys(local.workload_policies), "${operator.cluster_name}-external-secrets") ? vault_policy.workload["${operator.cluster_name}-external-secrets"].name : null
        # The Bastion Vault holds the cluster-config of the Downstream Vault cluster, since that cluster precedes its own Vault.
        cluster_config = {
          vault    = key == "vault-downstream" ? "bastion" : "downstream"
          kv_mount = key == "vault-downstream" ? "secret" : vault_mount.kv.path
          kv_path  = local.foundation_kv_paths[operator.service][operator.component].cluster_config
        }
      } if operator.service == service
    }
  }
}

output "downstream_vault_owners" {
  description = "Login coordinates of every external owner, keyed by owner code: the Downstream endpoint and CA, the SPIRE Child JWT mount and audience, the operator and workload roles with their policies and SPIFFE ID prefixes, the KV mount and the registration kubeconfig path, the owner PKI and node attestation PKI mounts with the role named by the owner code, and the services and networks of the owner."
  value = {
    for owner, o in local.external_owners : owner => {
      endpoint     = local.downstream_vault_config.endpoint
      ca_cert_path = local.downstream_vault_config.ca_cert_path
      auth_mount   = local.spire_child_jwt_auth.mount_path
      audience     = local.spire_child_jwt_auth.audience
      operator = {
        role_name     = o.operator_role
        policy_name   = vault_policy.external_owner_operator[owner].name
        spiffe_prefix = "spiffe://${local.spiffe_trust_domain}/${owner}/terraform-operator/"
      }
      workload = {
        role_name     = o.workload_role
        policy_name   = vault_policy.external_owner_workload[owner].name
        spiffe_prefix = "spiffe://${local.spiffe_trust_domain}/${owner}/"
      }
      kv_mount             = vault_mount.kv.path
      registration_kv_path = o.registration_kv_path
      pki                  = { mount_path = o.pki_mount_path, role_name = owner }
      node_pki             = { mount_path = local.node_pki_mount_path, role_name = owner }
      services             = o.services
      cidr_blocks          = o.cidr_blocks
    }
  }
}

output "spire_child_jwt_auth" {
  description = "Mount path and audience of the JWT backend of the SPIRE Child on the Downstream Vault, which provision-spire-child creates, the tenants whose roles the backend carries with the policy of the same name, and the operators of the components deployed after the SPIRE Child, keyed by role name."
  value = {
    mount_path = local.spire_child_jwt_auth.mount_path
    audience   = local.spire_child_jwt_auth.audience
    tenants    = { for name, t in local.child_tenants : name => { spiffe_id = t.spiffe_id, policy_name = vault_policy.tenant[name].name } }
    operators = {
      for key, operator in local.terraform_operators : operator.role_name => {
        spiffe_path = operator.spiffe_path
        spiffe_id   = "spiffe://${local.spiffe_trust_domain}${operator.spiffe_path}"
        policy_name = vault_policy.component_operator[key].name
      } if operator.server == "child"
    }
  }
}
