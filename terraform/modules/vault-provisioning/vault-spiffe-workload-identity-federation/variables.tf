# Documentation: documentation/architecture/platform-spire-parent-frontend.md Section 5.
variable "auth_role_name" {
  description = "Sets the JWT authentication backend role identifier for the target workload identity."
  type        = string
}

variable "auth_backend_path" {
  description = "Mount path of the shared vault_jwt_auth_backend resource."
  type        = string
}

variable "spiffe_id" {
  description = "Exact SPIFFE ID evaluated against the JWT-SVID sub claim."
  type        = string
}

variable "audience" {
  description = "Required aud claim value validated during JWT-SVID authentication."
  type        = string
  default     = "vault"
}

variable "token_policies" {
  description = "Names of the existing policies which are attached to the token besides default. The caller does not write the policies through this module."
  type        = list(string)

  validation {
    condition     = length(var.token_policies) > 0
    error_message = "token_policies MUST name at least one policy."
  }
}

variable "token_ttl" {
  description = "TTL in seconds for tokens issued upon JWT authentication."
  type        = number
  default     = 3600
}

variable "token_max_ttl" {
  description = "Maximum TTL in seconds for tokens issued upon JWT authentication."
  type        = number
  default     = 86400
}
