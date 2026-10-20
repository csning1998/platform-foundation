
output "downstream_pki_trust_bundle_path" {
  description = "Absolute path to the combined CA trust bundle, for manual import into a local OS/browser trust store."
  value       = abspath(local_file.trust_bundle.filename)
}

output "downstream_pki_issuer_cert_b64" {
  description = "Base64-encoded, signed Production Issuing Intermediate CA certificate only, for server-served TLS chains (excludes the Root CA)."
  value       = module.vault_pki_setup.pki_issuer_cert_b64
}

output "bastion_pki_chain_b64" {
  description = "Export CA trust bundle file path and Base64-encoded string representation for inline consumption."
  value = {
    path        = abspath(local_file.trust_bundle.filename)
    content_b64 = base64encode(local_file.trust_bundle.content)
  }
}

output "downstream_pki_configuration" {
  description = "Export Downstream PKI mount point and service role mappings. The leaf role itself, not a client-requested value, governs its own issued certificate TTL."
  value = {
    path       = module.vault_pki_setup.pki_issuer_mount_path
    leaf_roles = module.vault_pki_setup.pki_leaf_roles
  }
}

output "downstream_pki_management_policies" {
  description = "Map of human management identities (oidc-admin, oidc-auditor, oidc-developer) to their Vault ACL policy names, for OIDC group-to-policy mapping."
  value       = { for k in local.management_identities : k => vault_policy.management[k].name }
}

output "downstream_pki_issuer_chain_pem" {
  description = "Certificate chain which a leaf of the Downstream issuer appends: the Downstream issuer, pki-intermediate-vault-downstream, and the Bastion root."
  value       = "${trimspace(base64decode(module.vault_pki_setup.pki_issuer_cert_b64))}\n${trimspace(local.bastion_pki_downstream_cert_pem)}\n${trimspace(local.registry_bastion.pki.trust_anchors[local.bastion_pki_downstream.root_ca_id])}\n"
}

output "spire_node_pki" {
  description = "Node attestation PKI: the mount, the intermediate CA certificate which the x509pop node attestor of the SPIRE Child trusts, and the role of each owner code, which issues only common names starting with that owner code."
  value = {
    mount_path  = vault_mount.intermediate[local.node_pki_mount].path
    ca_cert_pem = vault_pki_secret_backend_root_sign_intermediate.intermediate[local.node_pki_mount].certificate
    role_names  = { for owner, role in vault_pki_secret_backend_role.node : owner => role.name }
  }
}

output "owner_pki" {
  description = "PKI intermediate of every external owner, keyed by owner code: the mount, the role, and the issuer chain which a leaf of the owner appends, from the owner intermediate up to the Bastion root."
  value = {
    for owner, o in local.owners : owner => {
      mount_path = vault_mount.intermediate[o.pki.mount_path].path
      role_name  = vault_pki_secret_backend_role.owner[owner].name
      issuer_chain_pem = join("\n", [
        trimspace(vault_pki_secret_backend_root_sign_intermediate.intermediate[o.pki.mount_path].certificate),
        trimspace(base64decode(module.vault_pki_setup.pki_issuer_cert_b64)),
        trimspace(local.bastion_pki_downstream_cert_pem),
        trimspace(local.registry_bastion.pki.trust_anchors[local.bastion_pki_downstream.root_ca_id]),
      ])
    }
  }
}

output "trust_bundle_pem" {
  description = "Public certificates which verify every platform endpoint, including the Bastion listener and the Bastion root, for consumers which verify Bastion side endpoints without a Bastion Vault identity."
  value       = local.trust_bundle_pem
}
