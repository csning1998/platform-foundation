// Package vaultops provides Bastion Vault connectivity resolution and status inspection,
// as well as the unseal of the Downstream Vault on the VM runtime.
package vaultops

import (
	"context"

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

// SealStatus is the reachability, initialization, and seal state of one Vault instance.
type SealStatus = vaultclient.SealStatus

// InspectStatusAt queries the Vault instance at addr, verifying its TLS certificate against
// caCert. A zero SealStatus means the instance did not respond.
func InspectStatusAt(ctx context.Context, addr, caCert string) SealStatus {
	return vaultclient.InspectStatus(ctx, vaultclient.Config{
		Address:    addr,
		CACertPath: caCert,
	})
}

// InspectBastionStatus queries the full seal status of the Bastion Vault.
func InspectBastionStatus(ctx context.Context, p Paths) SealStatus {
	return InspectStatusAt(ctx, p.bastionVaultAddr, p.bastionVaultCACert)
}

// GetBastionStatus checks whether Bastion Vault is reachable and reports its sealed state.
func GetBastionStatus(ctx context.Context, p Paths) (running, sealed bool, err error) {
	client, err := vaultclient.NewClient(vaultclient.Config{
		Address:    p.bastionVaultAddr,
		CACertPath: p.bastionVaultCACert,
	})
	if err != nil {
		return false, false, err
	}
	return vaultclient.ProbeState(ctx, client)
}

// ReadKVv2Field reads mountPath/data/secretPath from a KV v2 engine and returns the specified field value.
func ReadKVv2Field(ctx context.Context, client *vaultapi.Client, mountPath, secretPath, field string) (value string, ok bool) {
	return vaultclient.ReadKVv2Field(ctx, client, mountPath, secretPath, field)
}
