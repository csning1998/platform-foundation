
# Each owner intermediate excludes the names of the platform and of every other owner, since the glob of a PKI role matches across a dot.
locals {
  owners             = local.state.security_vault_downstream_tenants.downstream_vault_owners
  node_pki_mount     = local.state.security_vault_downstream_tenants.spire_node_pki.mount_path
  stage_domains      = jsondecode(nonsensitive(data.vault_generic_secret.registry_platform_network_allocation.data["stage_domains"]))
  platform_dns_names = distinct(flatten([for item in local.state.foundation_libvirt_resources.foundation_pki.map : item.dns_san]))

  owner_service_names = {
    for owner, o in local.owners : owner => flatten([for service in o.services : [for base in local.stage_domains : "${service}.${base}"]])
  }
  owner_allowed_domains = {
    for owner, o in local.owners : owner => concat([for base in local.stage_domains : "${owner}-*.${base}"], local.owner_service_names[owner])
  }
  owner_excluded_dns_domains = {
    for owner, o in local.owners : owner => flatten([
      for name in concat(local.platform_dns_names, flatten([for other, names in local.owner_service_names : names if other != owner])) : [name, ".${name}"]
    ])
  }

  intermediates = merge(
    {
      (local.node_pki_mount) = {
        common_name          = "On-prem SPIRE Node Attestation Intermediate CA"
        permitted_ip_ranges  = []
        excluded_dns_domains = []
      }
    },
    {
      for owner, o in local.owners : o.pki.mount_path => {
        common_name          = "On-prem ${owner} Owner Intermediate CA"
        permitted_ip_ranges  = o.cidr_blocks
        excluded_dns_domains = local.owner_excluded_dns_domains[owner]
      }
    },
  )

  # The platform and every owner attest VM agents with a node certificate whose common name starts with the owner code.
  node_role_owners = concat([local.foundation_project_code], keys(local.owners))
}

resource "vault_mount" "intermediate" {
  provider = vault.downstream
  for_each = local.intermediates

  path                      = each.key
  type                      = "pki"
  description               = each.value.common_name
  default_lease_ttl_seconds = local.pki_lease_ttl_seconds
  max_lease_ttl_seconds     = local.pki_lease_ttl_seconds
}

resource "vault_pki_secret_backend_intermediate_cert_request" "intermediate" {
  provider = vault.downstream
  for_each = local.intermediates

  backend     = vault_mount.intermediate[each.key].path
  type        = "internal"
  common_name = each.value.common_name
  key_type    = "ec"
  key_bits    = 256
  key_name    = "issuer-ec256-${vault_mount.intermediate[each.key].accessor}"
}

# A change of the Name Constraints signs the same key again, and the mount issues from the new issuer.
resource "vault_pki_secret_backend_root_sign_intermediate" "intermediate" {
  provider = vault.downstream
  for_each = local.intermediates

  backend              = module.vault_pki_setup.pki_issuer_mount_path
  csr                  = vault_pki_secret_backend_intermediate_cert_request.intermediate[each.key].csr
  common_name          = each.value.common_name
  format               = "pem"
  ttl                  = local.pki_lease_ttl_seconds
  exclude_cn_from_sans = true
  permitted_ip_ranges  = each.value.permitted_ip_ranges
  excluded_dns_domains = each.value.excluded_dns_domains
}

resource "vault_pki_secret_backend_intermediate_set_signed" "intermediate" {
  provider = vault.downstream
  for_each = local.intermediates

  backend     = vault_mount.intermediate[each.key].path
  certificate = vault_pki_secret_backend_root_sign_intermediate.intermediate[each.key].certificate
}

# set-signed leaves the previous issuer as the default, which keeps issuing under the previous Name Constraints.
resource "vault_pki_secret_backend_config_issuers" "intermediate" {
  provider = vault.downstream
  for_each = local.intermediates

  backend                       = vault_mount.intermediate[each.key].path
  default                       = vault_pki_secret_backend_intermediate_set_signed.intermediate[each.key].imported_issuers[0]
  default_follows_latest_issuer = true
}

resource "vault_pki_secret_backend_config_urls" "intermediate" {
  provider = vault.downstream
  for_each = local.intermediates

  backend                 = vault_mount.intermediate[each.key].path
  issuing_certificates    = ["${local.downstream_vault.endpoint}/v1/${vault_mount.intermediate[each.key].path}/ca"]
  crl_distribution_points = ["${local.downstream_vault.endpoint}/v1/${vault_mount.intermediate[each.key].path}/crl"]
}

resource "vault_pki_secret_backend_role" "owner" {
  provider   = vault.downstream
  for_each   = local.owners
  depends_on = [vault_pki_secret_backend_config_issuers.intermediate]

  backend            = vault_mount.intermediate[each.value.pki.mount_path].path
  name               = each.value.pki.role_name
  allowed_domains    = local.owner_allowed_domains[each.key]
  allow_glob_domains = true
  allow_subdomains   = true
  allow_bare_domains = true
  allow_ip_sans      = true
  allow_any_name     = false
  enforce_hostnames  = true
  require_cn         = true

  key_type  = "ec"
  key_bits  = 256
  key_usage = ["DigitalSignature"]

  server_flag = true
  client_flag = true

  max_ttl = 60 * 60 * 24 * 90
  ttl     = 60 * 60 * 24 * 30
}

resource "vault_pki_secret_backend_role" "node" {
  provider   = vault.downstream
  for_each   = toset(local.node_role_owners)
  depends_on = [vault_pki_secret_backend_config_issuers.intermediate]

  backend            = vault_mount.intermediate[local.node_pki_mount].path
  name               = each.key
  allowed_domains    = [for base in local.stage_domains : "${each.key}-*.${base}"]
  allow_glob_domains = true
  allow_subdomains   = false
  allow_bare_domains = false
  allow_ip_sans      = false
  allow_any_name     = false
  enforce_hostnames  = true
  require_cn         = true

  key_type  = "ec"
  key_bits  = 256
  key_usage = ["DigitalSignature"]

  server_flag = false
  client_flag = true

  max_ttl = 60 * 60 * 24 * 90
  ttl     = 60 * 60 * 24 * 30
}
