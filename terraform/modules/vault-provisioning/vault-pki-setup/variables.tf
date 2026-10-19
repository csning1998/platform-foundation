
variable "vault_endpoint" {
  description = "Network endpoint address of the target Vault server where the intermediate PKI engine is mounted."
  type        = string
}

variable "pki_settings" {
  description = "Certificate parameters of the downstream intermediate CA: the common name, and the DNS names which the signing request carries. A signer with permitted DNS Name Constraints rejects a CA certificate without a DNS name inside the permitted subtree."
  type = object({
    intermediate_ca_common_name = string
    intermediate_dns_names      = list(string)
  })

  validation {
    condition     = length(var.pki_settings.intermediate_dns_names) > 0
    error_message = "pki_settings.intermediate_dns_names MUST name at least one DNS name inside the permitted subtree of the signer."
  }
}

variable "pki_roles" {
  description = "Specification map defining certificate issuance parameters and domain constraints per service role."
  type = map(object({
    name            = string
    auth_method     = string
    auth_path       = string
    allowed_domains = list(string)
    ou              = list(string)
    max_ttl         = number
    ttl             = number
  }))
}

variable "pki_engine_config" {
  description = "Mount path and lease duration parameters for the downstream PKI secrets engine."
  type = object({
    path                      = string
    default_lease_ttl_seconds = number
    max_lease_ttl_seconds     = number
  })
}

variable "bastion_pki_inter_mount_path" {
  description = "Mount path of the constrained Bastion Vault PKI engine which signs the CSR, such as pki-intermediate-vault-downstream."
  type        = string
}
