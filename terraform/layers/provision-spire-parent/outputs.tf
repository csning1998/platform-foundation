
output "terraform_operator" {
  description = "Identity of the local Terraform operator of each component deployed before the SPIRE Child, keyed as in _spire_parent_operator_targets: the SPIRE server which attests the operator, the JWT role name on the Downstream Vault, the name of the JWT-SVID fetch wrapper, the SPIFFE path, and the catalog service, component, and cluster name."
  value       = local.spire_parent_operators
}
