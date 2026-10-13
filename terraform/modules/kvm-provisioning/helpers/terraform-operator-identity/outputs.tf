
output "operator_identity" {
  description = "Keys of the targets which the topology lacks, and the login identity of every other operator keyed as in targets: the SPIRE server, the role name on the Downstream Vault, the JWT-SVID wrapper name, the SPIFFE path, and the catalog service, component, and cluster name."
  value = {
    missing_targets = local.missing_targets
    operators       = local.operators
  }
}
