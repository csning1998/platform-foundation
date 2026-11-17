
# The registry part of Harbor Origin precedes every Talos cluster. The OIDC part, which depends on Keycloak, resides in provision-harbor-origin-oidc.

data "terraform_remote_state" "security_vault_downstream_tenants" {
  backend = "http"
  config  = { address = "${local._state_base}/security-vault-downstream-tenants" }
}

data "terraform_remote_state" "platform_harbor_origin_frontend" {
  backend = "http"
  config  = { address = "${local._state_base}/platform-harbor-origin-frontend" }
}

ephemeral "vault_kv_secret_v2" "harbor_origin" {
  provider = vault.downstream
  mount    = "secret"
  name     = local.downstream_kv_paths["harbor-origin"]["frontend"].app
}

# Downstream consumers authenticate private OCI chart operations through credentials stored in the Downstream Vault.
# This layer MUST choose the robot passwords to synchronize authentication state across Harbor and Vault simultaneously.
ephemeral "random_password" "robot_secret" {
  for_each = toset(["helm_puller", "helm_pusher"])

  length      = 32
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}
