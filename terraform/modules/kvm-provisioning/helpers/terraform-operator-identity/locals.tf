
locals {
  # A target absent from the topology renders as a missing key here instead of an opaque "Invalid index" crash below.
  missing_targets = [
    for key, t in var.operator_identity_config.targets :
    key if !contains(keys(lookup(var.operator_identity_config.topology_identity, t.service, {})), t.component)
  ]

  # The identity string <owner>-terraform-operator-<service>-<component> names the role and the policy on the Downstream Vault.
  # The platform CLI derives the same wrapper name from terraform_operator_subject of each layer.
  operators = {
    for key, t in var.operator_identity_config.targets : key => {
      server       = var.operator_identity_config.server
      role_name    = "${t.owner}-terraform-operator-${t.service}-${t.component}"
      wrapper_name = "spire-fetch-${t.owner}-terraform-operator-${t.service}-${t.component}"
      spiffe_path  = "/${t.owner}/terraform-operator/${t.service}/${t.component}"
      service      = t.service
      component    = t.component
      cluster_name = var.operator_identity_config.topology_identity[t.service][t.component].cluster_name
    }
    if !contains(local.missing_targets, key)
  }
}
