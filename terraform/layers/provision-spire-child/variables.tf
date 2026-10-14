
variable "spire_crds_chart_version" {
  description = "Helm chart version for spire-crds CustomResourceDefinitions."
  type        = string
}

variable "spire_nested_chart_version" {
  description = "Helm chart version for spire-nested. AppVersion MUST match the parent SPIRE server release."
  type        = string
}

variable "local_path_provisioner_chart_version" {
  description = "Helm chart version for local-path-provisioner, which serves the datastore claim of the SPIRE Child server."
  type        = string
}

variable "spire_child_ca_subject_country" {
  description = "Country code for child SPIRE server intermediate CA certificate subject."
  type        = string
}
