
data "terraform_remote_state" "platform_cilium_hubble" {
  backend = "http"
  config  = { address = "${local._state_base}/platform-cilium-hubble" }
}

data "terraform_remote_state" "foundation_libvirt_resources" {
  backend = "http"
  config  = { address = "${local._state_base}/foundation-libvirt-resources" }
}

data "terraform_remote_state" "security_vault_downstream_tenants" {
  backend = "http"
  config  = { address = "${local._state_base}/security-vault-downstream-tenants" }
}

ephemeral "vault_kv_secret_v2" "cilium_hubble" {
  provider = vault.downstream
  mount    = "secret"
  name     = local.state.foundation_libvirt_resources.foundation_vault_path.kv_paths["cilium"]["hubble"].cluster_config
}

# Cluster readiness checks MUST re-validate quorum convergence during apply operations
# because concurrent disk writes from sibling layers destabilize etcd consensus.
ephemeral "talos_cluster_health" "this" {
  client_configuration = {
    ca_certificate     = ephemeral.vault_kv_secret_v2.cilium_hubble.data["talos_ca_certificate_b64"]
    client_certificate = ephemeral.vault_kv_secret_v2.cilium_hubble.data["talos_client_certificate_b64"]
    client_key         = ephemeral.vault_kv_secret_v2.cilium_hubble.data["talos_client_key_b64"]
  }
  control_plane_nodes = values(local.state.platform_cilium_hubble.talos_cluster.hostonly_addresses)
  endpoints           = values(local.state.platform_cilium_hubble.talos_cluster.hostonly_addresses)

  timeout = "10m"
}
