
# Declarations of the VM runtime alone. Each resource and module carries count = local.is_runtime_talos ? 0 : 1.
# Ansible issues the listener certificate through the Vault Proxy, and initializes and unseals the raft cluster with the
# Shamir keys of the init leaf. Neither the private key nor the init secrets enter a Terraform state.
locals {
  vm_ansible_template_config = {
    global_mss                  = module.terraform_layer_context.global_mss
    vault_vip                   = module.terraform_layer_context.primary_network_config.lb_config.vip
    platform_vault_cluster_name = local.vault_downstream_cluster_name
  }

  # Variables which the unseal tasks of platform_vault read, also exported for the post-reboot unseal of the platform CLI.
  vm_ansible_unseal_vars = {
    platform_vault_init_kv_path    = local.foundation_kv_paths.init
    platform_vault_ca_chain_b64    = base64encode(local.listener_ca_chain_pem)
    platform_vault_tls_server_name = module.terraform_layer_context.cluster_fqdn
  }

  vm_ansible_extra_config = merge(local.vm_ansible_unseal_vars, {
    ansible_user                  = module.terraform_layer_context.security_vm_credentials.username
    platform_vault_common_name    = module.terraform_layer_context.cluster_fqdn
    platform_vault_pki_mount_path = local.bastion_pki_platform.mount_path
    platform_vault_pki_role_name  = one(vault_pki_secret_backend_role.vm_listener[*].name)
    platform_vault_alt_names      = join(",", local.vault_listener_dns_names)
  })
}

# The role name equals the cluster name, which the tenant ACL scopes by the owner code prefix.
# Each node issues a certificate for its own address and the VIP, and the raft peers verify each other through the IP SANs.
resource "vault_pki_secret_backend_role" "vm_listener" {
  count    = local.is_runtime_talos ? 0 : 1
  provider = vault.bastion
  backend  = local.bastion_pki_platform.mount_path
  name     = local.vault_downstream_cluster_name

  allowed_domains    = local.vault_listener_dns_names
  allow_bare_domains = true
  allow_subdomains   = false
  allow_glob_domains = false
  allow_ip_sans      = true
  enforce_hostnames  = true
  require_cn         = true
  allow_any_name     = false

  key_type    = "ec"
  key_bits    = 256
  key_usage   = ["DigitalSignature"]
  server_flag = true
  client_flag = true

  max_ttl = 60 * 60 * 24 * 90 # 90 Days
  ttl     = 60 * 60 * 24 * 90 # 90 Days

  ou = local.state.foundation_libvirt_resources.foundation_pki.map[module.terraform_layer_context.primary_context.pki_key].ou
}

# Matches the cluster inventory naming to allow automated pairing of unseal variables in the platform CLI.
resource "local_file" "unseal_vars" {
  count = local.is_runtime_talos ? 0 : 1

  content              = jsonencode(local.vm_ansible_unseal_vars)
  filename             = abspath("${path.root}/../../../ansible/inventory-${local.vault_downstream_cluster_name}-unseal-vars.json")
  file_permission      = "0644"
  directory_permission = "0755"
}

module "establish_platform_vault_generic_cluster" {
  count             = local.is_runtime_talos ? 0 : 1
  source            = "../../modules/kvm-provisioning/orchestrate/linux-generic-cluster"
  ansible_root_path = local.state.foundation_libvirt_resources.foundation_paths.ansible_root
  scripts_root_path = local.state.foundation_libvirt_resources.foundation_paths.scripts_root

  cluster_identity           = module.terraform_layer_context.cluster_identity
  node_identities            = module.terraform_layer_context.node_identities
  topology_cluster           = module.terraform_layer_context.topology_cluster
  network_infrastructure_map = module.terraform_layer_context.network_infrastructure_map
  storage_infrastructure_map = local.state.foundation_libvirt_resources.foundation_storage.infrastructure
  ssh_config_path            = local.state.foundation_libvirt_resources.foundation_ssh.config_paths[local.vault_downstream_cluster_name]

  credentials_system = merge(module.terraform_layer_context.security_vm_credentials, {
    ssh_private_key_path = local.state.foundation_libvirt_resources.foundation_ssh.identity_key_paths[local.vault_downstream_cluster_name]
    ssh_public_key_path  = local.state.foundation_libvirt_resources.foundation_ssh.public_key_paths[local.vault_downstream_cluster_name]
  })

  ansible_generic_config = {
    template_vars = local.vm_ansible_template_config
    extra_vars    = local.vm_ansible_extra_config
  }
}
