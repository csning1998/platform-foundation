
# Configures Downstream PKI issuing intermediate and workload roles per Section 1 Item C.
# Retains the private key locally within Downstream Vault and transmits only the CSR to Bootstrap Vault.
module "vault_pki_setup" {
  source = "../../modules/vault-provisioning/vault-pki-setup"
  providers = {
    vault.issuing = vault.downstream
    vault.signing = vault.bastion
  }

  vault_endpoint = local.downstream_vault.endpoint
  pki_settings = {
    intermediate_ca_common_name = local.state.platform_vault_downstream_frontend.pki_identity.intermediate_ca_common_name
    intermediate_dns_names      = [local.state.platform_vault_downstream_frontend.listener_identity.common_name]
  }
  pki_roles = local.pki_roles
  pki_engine_config = {
    path                      = local.downstream_vault.pki_mount_path
    default_lease_ttl_seconds = local.pki_lease_ttl_seconds
    max_lease_ttl_seconds     = local.pki_lease_ttl_seconds
  }
  bastion_pki_inter_mount_path = local.bastion_pki_downstream.mount_path
}

# The ACL policies of the human management identities. The policy name equals the identity name.
# provision-vault-oidc maps each OIDC group to the policy of the identity. Workloads on VMs and in Kubernetes log in
# with a JWT-SVID through the tenant registry of security-vault-downstream-tenants.
resource "vault_policy" "management" {
  provider = vault.downstream
  for_each = local.management_identities

  name = each.key
  policy = jsonencode({
    path = merge(
      {
        "${module.vault_pki_setup.pki_issuer_mount_path}/issue/${local.pki_roles[each.key].name}" = {
          capabilities = ["create", "update"]
        }
      },
      local.workload_identity_extra_rules[each.key]
    )
  })
}

# Combined certificate chain for local trust store installation: the Bastion listener CA, which is distinct from the PKI roots,
# the Bastion root with pki-intermediate-vault-downstream, pki-leaf-platform which signs the Downstream Vault listener, and the Downstream issuer.
locals {
  trust_bundle_roots_pem = [
    for root_id in distinct([
      local.bastion_pki_downstream.root_ca_id,
      local.bastion_pki_platform.root_ca_id,
    ]) : trimspace(local.registry_bastion.pki.trust_anchors[root_id])
  ]

  trust_bundle_pem = join("\n", concat(
    [chomp(local.registry_bastion.vault.listener_ca_cert_pem)],
    local.trust_bundle_roots_pem,
    [
      trimspace(local.bastion_pki_downstream_cert_pem),
      chomp(local.bastion_pki_platform_cert_pem),
      chomp(base64decode(module.vault_pki_setup.pki_issuer_cert_b64)),
    ]
  ))
}

resource "local_file" "trust_bundle" {
  content              = local.trust_bundle_pem
  filename             = "${path.module}/tls/trust-bundle.crt"
  file_permission      = "0644"
  directory_permission = "0755"
}

# Trust anchors of the GUI frontends for a workstation, in place of the bundle and its unconstrained roots.
# The name constraints of pki-intermediate-vault-downstream and pki-leaf-platform bound the trust to the platform names.
resource "local_file" "frontend_trust_anchors" {
  content = join("\n", [
    trimspace(local.bastion_pki_downstream_cert_pem),
    chomp(local.bastion_pki_platform_cert_pem),
  ])
  filename             = "${path.module}/tls/anchors/frontend-trust-anchors.crt"
  file_permission      = "0644"
  directory_permission = "0755"
}
