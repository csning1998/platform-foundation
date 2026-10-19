
# pki-leaf-platform permits the platform domain and the cluster domain alone, hence the listener names of both runtimes exclude
# localhost and a bare Service name.
locals {
  vault_listener_dns_names    = local.state.foundation_libvirt_resources.foundation_pki.map[module.terraform_layer_context.primary_context.pki_key].dns_san
  vault_listener_ip_addresses = concat([module.terraform_layer_context.primary_network_config.lb_config.vip], module.terraform_layer_context.cluster_network.node_ips)
}

# Write the CA chain of the listener to the tls/ directory, which the Vault provider of every Downstream layer reads.
resource "local_file" "listener_ca_chain" {
  content              = local.listener_ca_chain_pem
  filename             = "${path.root}/tls/listener-ca-chain.crt"
  file_permission      = "0644"
  directory_permission = "0755"
}
