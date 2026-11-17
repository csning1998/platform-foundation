
# The names derive from the inputs alone, hence the listener certificate reads the output before the release exists.
output "listener_names" {
  description = "DNS names which the listener certificate MUST contain: the Service, the active Service, the headless Service, and every raft peer under the cluster domain."
  value = {
    service_domain = local.service_domain
    dns_names = concat(
      [for service in ["", "-active", "-internal"] : "${local.release_name}${service}.${local.service_domain}"],
      local.peer_names,
    )
  }
}

output "vault_servers" {
  description = "Coordinates which the init and unseal play reads: the namespace, the pod names in ordinal order, and the container name."
  value = {
    namespace = var.helm_config.namespace
    pods      = [for ordinal in range(var.raft_config.replicas) : "${local.release_name}-${ordinal}"]
    container = local.release_name
    release   = "${helm_release.vault.name}-${helm_release.vault.metadata.revision}"
    seal      = local.transit_enabled ? "transit" : "shamir"
  }
}
