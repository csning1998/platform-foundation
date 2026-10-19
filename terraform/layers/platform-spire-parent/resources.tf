
# The SPIRE Server signs its own intermediate CA against pki-intermediate-spire, whose Name Constraints bind the SPIRE trust domains.
# The AppRole below is the only identity which may call sign-intermediate, through the signer policy which pgg declares.
locals {
  # The secret ID and the token work only from the addresses of the SPIRE Parent nodes on the Bastion network.
  upstream_authority_source_cidrs = [
    for node in values(var.service_config[var.primary_role].nodes) :
    "${split("/", node.extra_networks[local.state.foundation_libvirt_resources.foundation_bastion_network.network_name])[0]}/32"
  ]
}

# Ansible issues the secret ID through the Vault Proxy and writes the secret ID to the host, outside the state.
resource "vault_approle_auth_backend_role" "spire_parent_upstream_authority" {
  backend               = local.registry_bastion.vault.approle_mount_path
  role_name             = "${module.terraform_layer_context.cluster_identity.cluster_name}-upstream-authority"
  token_policies        = [local.bastion_pki_spire.assignable_policy]
  token_ttl             = 60 * 60     # 1 Hour
  token_max_ttl         = 60 * 60 * 4 # 4 Hours
  token_bound_cidrs     = local.upstream_authority_source_cidrs
  secret_id_bound_cidrs = local.upstream_authority_source_cidrs

  lifecycle {
    precondition {
      condition     = contains(local.registry_spire_trust_domains, local.spiffe_trust_domain)
      error_message = "The SPIRE trust domain ${local.spiffe_trust_domain} is absent from spire_trust_domains of registry/platform/trust, and pki-intermediate-spire would reject every SPIRE CA of the trust domain."
    }
  }
}

# Documentation: documentation/architecture/platform-spire-parent-frontend.md Section 1 Item D.
# The role name equals the identity string of the service, which the tenant ACL scopes by the owner code prefix.
resource "vault_pki_secret_backend_role" "oidc_discovery" {
  backend = local.bastion_pki_platform.mount_path
  name    = module.terraform_layer_context.cluster_identity.cluster_name

  allowed_domains    = local.state.foundation_libvirt_resources.foundation_pki.map[module.terraform_layer_context.primary_context.pki_key].dns_san
  allow_bare_domains = true
  allow_subdomains   = false
  allow_glob_domains = false
  allow_ip_sans      = true
  enforce_hostnames  = true
  require_cn         = true
  allow_any_name     = false

  key_type    = "ec"
  key_bits    = 256
  key_usage   = ["DigitalSignature"]
  server_flag = true
  client_flag = true

  max_ttl = 60 * 60 * 24 * 90 # 90 Days
  ttl     = 60 * 60 * 24 * 90 # 90 Days

  ou = local.state.foundation_libvirt_resources.foundation_pki.map[module.terraform_layer_context.primary_context.pki_key].ou
}
