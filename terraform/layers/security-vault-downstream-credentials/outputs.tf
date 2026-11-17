
# A KV mount and path are coordinates of the secret. nonsensitive() strips the blanket mark
# which the module applies to the whole secret object.
output "credential_paths" {
  description = "Downstream Vault KV mount and path of every generated credential, keyed by service name."
  value = {
    keycloak_frontend      = { mount = nonsensitive(module.credential_keycloak_frontend.secret.mount), path = nonsensitive(module.credential_keycloak_frontend.secret.path) }
    harbor_origin_frontend = { mount = nonsensitive(module.credential_harbor_origin_frontend.secret.mount), path = nonsensitive(module.credential_harbor_origin_frontend.secret.path) }
    cilium_hubble_ui       = { mount = nonsensitive(module.credential_cilium_hubble_ui.secret.mount), path = nonsensitive(module.credential_cilium_hubble_ui.secret.path) }
  }
}
