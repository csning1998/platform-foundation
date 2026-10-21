package config

// Values which parent-group-governance owns. A rename upstream MUST be followed here alone.
// A .env key of the same name overrides each default, and BootstrapEnv MUST NOT copy a default into .env.
const (
	// DefaultBastionVaultAddr is the publish listener of Bastion Vault.
	DefaultBastionVaultAddr = "https://172.16.0.1:8200"
	// DefaultBastionVaultCACert is the relocatable path to the EC P-384 root CA which signs the publish listener.
	DefaultBastionVaultCACert = "${PROJECT_ROOT}/../../parent-group-governance/vault/tls/ca-ec-p384.pem"
	// VaultProxyIdentity is the operator identity of the Vault Proxy which serves the layers of this repository.
	VaultProxyIdentity = "platform-foundation"
)
