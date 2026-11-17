
data "terraform_remote_state" "security_vault_downstream_tenants" {
  backend = "http"
  config  = { address = "${local._state_base}/security-vault-downstream-tenants" }
}

data "terraform_remote_state" "security_vault_downstream_pki" {
  backend = "http"
  config  = { address = "${local._state_base}/security-vault-downstream-pki" }
}

data "terraform_remote_state" "platform_keycloak_frontend" {
  backend = "http"
  config  = { address = "${local._state_base}/platform-keycloak-frontend" }
}

ephemeral "vault_kv_secret_v2" "keycloak_admin" {
  provider = vault.downstream
  mount    = "secret"
  name     = local.downstream_kv_paths["keycloak"]["frontend"].app
}

data "terraform_remote_state" "foundation_libvirt_resources" {
  backend = "http"
  config  = { address = "${local._state_base}/foundation-libvirt-resources" }
}

ephemeral "vault_kv_secret_v2" "keycloak_cluster" {
  count    = local.is_runtime_talos ? 1 : 0
  provider = vault.downstream
  mount    = "secret"
  name     = local.state.foundation_libvirt_resources.foundation_vault_path.kv_paths["keycloak"]["frontend"].cluster_config
}

# Cluster readiness checks MUST re-validate quorum convergence during apply operations.
ephemeral "talos_cluster_health" "this" {
  count = local.is_runtime_talos ? 1 : 0

  client_configuration = {
    ca_certificate     = ephemeral.vault_kv_secret_v2.keycloak_cluster[0].data["talos_ca_certificate_b64"]
    client_certificate = ephemeral.vault_kv_secret_v2.keycloak_cluster[0].data["talos_client_certificate_b64"]
    client_key         = ephemeral.vault_kv_secret_v2.keycloak_cluster[0].data["talos_client_key_b64"]
  }
  control_plane_nodes = values(local.state.platform_keycloak_frontend.talos_cluster.hostonly_addresses)
  endpoints           = values(local.state.platform_keycloak_frontend.talos_cluster.hostonly_addresses)

  timeout = "10m"
}
