
# Every output is a category object.
output "runtime" {
  description = "Runtime of the component in the service catalog: the runtime name, and whether the runtime is Kubernetes native, which selects talos_cluster or generic_cluster."
  value = {
    name              = local.vault_downstream_cluster_runtime
    kubernetes_native = local.is_runtime_talos
  }
}

output "vault_endpoint" {
  description = "Connection facts of the Downstream Vault, which both runtimes publish on the VIP: the API URL, the VIP, the API port, and the path of the CA chain of the listener, the Bastion root and the pki-leaf-platform intermediate."
  value = {
    address      = "https://${module.terraform_layer_context.primary_network_config.lb_config.vip}:${module.terraform_layer_context.primary_network_config.lb_config.ports["api"].frontend_port}"
    service_vip  = module.terraform_layer_context.primary_network_config.lb_config.vip
    api_port     = module.terraform_layer_context.primary_network_config.lb_config.ports["api"].frontend_port
    ca_cert_path = abspath(local_file.listener_ca_chain.filename)
  }
}

output "listener_identity" {
  description = "Names and addresses which the Vault listener certificate carries on both runtimes: the common name, the DNS names, and the IP addresses. The Talos runtime adds the Service names of the chart."
  value = {
    common_name  = module.terraform_layer_context.cluster_fqdn
    dns_names    = local.vault_listener_dns_names
    ip_addresses = local.vault_listener_ip_addresses
  }
}

output "pki_identity" {
  description = "Identity of the intermediate CA which the Downstream Vault holds, for the layers which create the PKI engine and its policies."
  value       = var.pki_identity
}

# Terraform does not persist an output whose value is null, hence a runtime object always exists for terraform_remote_state.
# The fields of the object of the runtime which the catalog does not select are null.
output "talos_cluster" {
  description = "Facts of the Talos runtime, with null fields on the VM runtime: whether the runtime applies, the HostOnly address per node, the bootstrap node, the raft volume mount, the cert-manager ClusterIssuer against pki-platform, the Vault workload identity, and the transit seal against the Bastion Vault."
  value = {
    enabled            = local.is_runtime_talos
    hostonly_addresses = one(module.establish_platform_vault_talos_cluster[*].hostonly_addresses)
    bootstrap_node_key = one(module.establish_platform_vault_talos_cluster[*].bootstrap_node_key)
    volume_mount_path  = one(module.establish_platform_vault_talos_cluster[*].volume_mount_path)
    cluster_issuer     = one(module.vault_kubernetes_auth_talos[*].cluster_issuer)
    vault_workload     = local.is_runtime_talos ? local.vault_workload : null
    transit_unseal = local.is_runtime_talos ? {
      address    = local.registry_bastion.vault.endpoint
      auth_path  = vault_kubernetes_auth_backend_role.transit_unseal[0].backend
      role_name  = vault_kubernetes_auth_backend_role.transit_unseal[0].role_name
      audience   = vault_kubernetes_auth_backend_role.transit_unseal[0].audience
      mount_path = local.registry_bastion.transit_unseal.mount_path
      key_name   = local.transit_unseal_consumer.key_name
    } : null
  }
}

output "generic_cluster" {
  description = "Facts of the VM runtime, with null fields on the Talos runtime: whether the runtime applies, the node addresses, the Node Exporter scrape targets, and the KV path of the init leaf which holds the Shamir keys."
  value = {
    enabled      = !local.is_runtime_talos
    node_ips     = local.is_runtime_talos ? null : module.terraform_layer_context.cluster_network.node_ips
    init_kv_path = local.is_runtime_talos ? null : local.foundation_kv_paths.init
    node_exporter_targets = local.is_runtime_talos ? null : {
      ips  = module.terraform_layer_context.cluster_network.node_ips
      port = module.terraform_layer_context.node_exporter_port
    }
  }
}
