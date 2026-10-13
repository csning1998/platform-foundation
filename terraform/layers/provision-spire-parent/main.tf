
module "spire_parent_operator_identity" {
  source = "../../modules/kvm-provisioning/helpers/terraform-operator-identity"

  operator_identity_config = {
    server            = "parent"
    targets           = local._spire_parent_operator_targets
    topology_identity = local.spire_parent_identity
  }
}

check "spire_parent_operator_targets_exist" {
  assert {
    condition     = length(module.spire_parent_operator_identity.operator_identity.missing_targets) == 0
    error_message = "_spire_parent_operator_targets names a component which foundation-libvirt-resources lacks: ${join(", ", module.spire_parent_operator_identity.operator_identity.missing_targets)}."
  }
}

# Registers the SPIRE Agent of the workstation and the JWT-SVID wrapper of every operator.
# The Vault roles of the operators belong to the Downstream Vault, which trusts the OIDC Discovery Provider of the SPIRE Parent.
module "ansible_operator_identity" {
  source = "../../modules/kvm-provisioning/configure/ansible-runner"

  status_trigger = local.spire_parent_operators
  ansible_config = local.ansible_config
  inventory_data = local.inventory_data
  extra_vars     = local.ansible_extra_vars
  ansible_tags   = ["spire_agent", "terraform_operator_identity", "terraform_operator_verify"]
  playbook_paths = [
    "${local.ansible_config.root_path}/playbooks/playbook_host_terraform_operator.yaml"
  ]
}
