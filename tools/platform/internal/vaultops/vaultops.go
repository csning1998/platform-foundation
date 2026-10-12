// Package vaultops provides Bastion Vault connectivity resolution and status inspection,
// as well as the unseal of the Downstream Vault on the VM runtime.
package vaultops

import (
	"context"
	"path/filepath"

	vaultapi "github.com/hashicorp/vault/api"

	"gitlab.com/csning1998-lab/parent-group-governance/tools/governance/pkg/vaultclient"
)

// Paths groups all project-relative and user-relative paths needed by Vault operations.
type Paths struct {
	ProjectRoot        string
	AnsibleDir         string
	TerraformDir       string
	Home               string
	bastionVaultAddr   string
	bastionVaultCACert string
	prodTokenRef       vaultclient.SecretRef
}

// NewPaths constructs Paths for a caller outside this package.
func NewPaths(projectRoot, ansibleDir, terraformDir, home, bastionVaultAddr, bastionVaultCACert string) Paths {
	return Paths{
		ProjectRoot:        projectRoot,
		AnsibleDir:         ansibleDir,
		TerraformDir:       terraformDir,
		Home:               home,
		bastionVaultAddr:   bastionVaultAddr,
		bastionVaultCACert: bastionVaultCACert,
	}
}

// WithProdTokenRef returns a copy of Paths configured with a custom Production Vault token reference.
func (p Paths) WithProdTokenRef(ref vaultclient.SecretRef) Paths {
	p.prodTokenRef = ref
	return p
}

func (p Paths) resolveProdTokenRef() vaultclient.SecretRef {
	if p.prodTokenRef == (vaultclient.SecretRef{}) {
		return ResolveProdTokenRef()
	}
	return p.prodTokenRef
}

func (p Paths) resolveBastionAddr() string {
	if p.bastionVaultAddr != "" {
		return p.bastionVaultAddr
	}
	return "https://172.16.0.1:8200"
}

func (p Paths) resolveTLSDir() string        { return filepath.Join(p.ProjectRoot, "vault", "tls") }
func (p Paths) resolveRootTokenFile() string { return filepath.Join(p.Home, ".vault-token") }
func (p Paths) resolveCACertFile() string {
	if p.bastionVaultCACert != "" {
		return p.bastionVaultCACert
	}
	return filepath.Join(p.resolveTLSDir(), "ca.pem")
}
func (p Paths) resolveProdCACertFile() string {
	return filepath.Join(p.TerraformDir, "layers", "shared-vault-frontend", "tls", "bootstrap-ca.crt")
}

// ProdCACertPath returns the on-disk path where shared-vault-frontend's Terraform output
// writes the Production Vault CA certificate.
func (p Paths) ProdCACertPath() string { return p.resolveProdCACertFile() }

// SealStatus is one Vault instance's reachability, initialization, and seal state.
type SealStatus = vaultclient.SealStatus

// InspectStatusAt queries the Vault instance at addr, verifying its TLS certificate against
// caCert. A zero SealStatus means the instance did not respond.
func InspectStatusAt(ctx context.Context, addr, caCert string) SealStatus {
	return vaultclient.InspectStatus(ctx, vaultclient.Config{
		Address:    addr,
		CACertPath: caCert,
	})
}

// InspectBastionStatus queries Bastion Vault's full seal status.
func InspectBastionStatus(ctx context.Context, p Paths) SealStatus {
	return InspectStatusAt(ctx, p.resolveBastionAddr(), p.resolveCACertFile())
}

// GetBastionStatus checks whether Bastion Vault is reachable and reports its sealed state.
func GetBastionStatus(ctx context.Context, p Paths) (running, sealed bool, err error) {
	client, err := vaultclient.NewClient(vaultclient.Config{
		Address:    p.resolveBastionAddr(),
		CACertPath: p.resolveCACertFile(),
	})
	if err != nil {
		return false, false, err
	}
	return vaultclient.ProbeState(ctx, client)
}

// SyncVaultToken extracts the root token from the user token file and updates the environment.
func SyncVaultToken(p Paths, env interface{ Set(string, string) }) (string, error) {
	return vaultclient.SyncSessionToken(p.Home, env)
}

// ReadKVv2Field reads mountPath/data/secretPath from a KV v2 engine and returns the specified field value.
func ReadKVv2Field(ctx context.Context, client *vaultapi.Client, mountPath, secretPath, field string) (value string, ok bool) {
	return vaultclient.ReadKVv2Field(ctx, client, mountPath, secretPath, field)
}
