package config

// Env key constants. Every .env key any package reads or writes is named here once.
// Outside this package or cmd/platform/main.go, code MUST reference these constants instead of string literals.
const (
	KeyProjectRoot         = "PROJECT_ROOT"
	KeyEnvironmentStrategy = "ENVIRONMENT_STRATEGY"
	KeyAllPackerBases      = "ALL_PACKER_BASES"
	KeyAllTerraformLayers  = "ALL_TERRAFORM_LAYERS"
	KeyBastionVaultAddr    = "BASTION_VAULT_ADDR"
	KeyBastionVaultCACert  = "BASTION_VAULT_CACERT"
	KeyVaultToken          = "VAULT_TOKEN"
	KeyHostUID             = "HOST_UID"
	KeyHostGID             = "HOST_GID"
	KeyUname               = "UNAME"
	KeyUhome               = "UHOME"
	KeyPKRVarNetBridge     = "PKR_VAR_NET_BRIDGE"
	KeyPKRVarNetDevice     = "PKR_VAR_NET_DEVICE"
	KeyLibvirtGID          = "LIBVIRT_GID"
	KeySSHPrivateKey       = "SSH_PRIVATE_KEY"

	StrategyNative    = "native"
	StrategyContainer = "container"

	// DefaultBastionVaultAddr is the default network address for Bastion Vault.
	DefaultBastionVaultAddr = "https://172.16.0.1:8200"
	// DefaultBastionVaultCACert is the default relocatable path to the parent group Bastion Vault CA certificate.
	DefaultBastionVaultCACert = "${PROJECT_ROOT}/../../parent-group-governance/vault/tls/ca.pem"
)
