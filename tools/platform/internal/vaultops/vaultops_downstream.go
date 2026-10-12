package vaultops

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/apenella/go-ansible/v2/pkg/playbook"

	"platform/internal/ansibleops"
	"platform/internal/ui"
)

// DownstreamLayer names the layer which renders the inventory and the unseal variables of the Downstream Vault.
const DownstreamLayer = "platform-vault-downstream-frontend"

var (
	// ErrProxyEnvironmentMissing reports a shell without the environment of the platform-foundation Vault Proxy.
	ErrProxyEnvironmentMissing = errors.New("vaultops: VAULT_ADDR, VAULT_CACERT, VAULT_TOKEN, VAULT_CLIENT_CERT, or VAULT_CLIENT_KEY is empty, allow the .envrc with direnv allow or run eval \"$(vault-proxy-env platform-foundation)\"")
	// ErrDownstreamInventoryMissing reports a Downstream Vault without the inventory of the VM runtime.
	ErrDownstreamInventoryMissing = errors.New("vaultops: the Downstream Vault has no VM runtime inventory, apply " + DownstreamLayer + " first, and the Talos runtime unseals through transit without this command")
)

// proxyEnvironmentKeys lists the variables which the ambient login of utils_vault_operator_login and group_vars read.
var proxyEnvironmentKeys = []string{"VAULT_ADDR", "VAULT_CACERT", "VAULT_TOKEN", "VAULT_CLIENT_CERT", "VAULT_CLIENT_KEY"}

var inventoryLineRe = regexp.MustCompile(`(?m)^inventory\s*=\s*(\S+)\s*$`)

// DownstreamInventory is the inventory and the unseal variables file which the Downstream layer rendered.
type DownstreamInventory struct {
	Inventory  string
	UnsealVars string
}

func (p Paths) resolveDownstreamLayerDir() string {
	return filepath.Join(p.TerraformDir, "layers", DownstreamLayer)
}

// ResolveDownstreamInventory reads the inventory path from the ansible.cfg which ansible-runner wrote into layerDir.
func ResolveDownstreamInventory(layerDir string) (DownstreamInventory, error) {
	data, err := os.ReadFile(filepath.Join(layerDir, "ansible.cfg"))
	if errors.Is(err, fs.ErrNotExist) {
		return DownstreamInventory{}, ErrDownstreamInventoryMissing
	}
	if err != nil {
		return DownstreamInventory{}, fmt.Errorf("vaultops: read the ansible.cfg of %s: %w", filepath.Base(layerDir), err)
	}
	match := inventoryLineRe.FindSubmatch(data)
	if match == nil {
		return DownstreamInventory{}, fmt.Errorf("%w: the ansible.cfg of %s declares no inventory", ErrDownstreamInventoryMissing, filepath.Base(layerDir))
	}
	inv := DownstreamInventory{Inventory: string(match[1])}
	inv.UnsealVars = strings.TrimSuffix(inv.Inventory, filepath.Ext(inv.Inventory)) + "-unseal-vars.json"
	for _, file := range []string{inv.Inventory, inv.UnsealVars} {
		if _, err := os.Stat(file); err != nil {
			return DownstreamInventory{}, fmt.Errorf("%w: %w", ErrDownstreamInventoryMissing, err)
		}
	}
	return inv, nil
}

// UnsealDownstream runs the vault-unseal tag of playbook_platform.yaml against the Downstream Vault nodes,
// which read the unseal keys from the Bastion Vault through the platform-foundation Vault Proxy.
func UnsealDownstream(ctx context.Context, p Paths, getenv func(string) string, out *ui.Printer) error {
	for _, key := range proxyEnvironmentKeys {
		if getenv(key) == "" {
			return ErrProxyEnvironmentMissing
		}
	}
	layerDir := p.resolveDownstreamLayerDir()
	inv, err := ResolveDownstreamInventory(layerDir)
	if err != nil {
		return err
	}

	opts := &playbook.AnsiblePlaybookOptions{
		Inventory:     inv.Inventory,
		Tags:          "vault-unseal",
		ExtraVarsFile: []string{"@" + inv.UnsealVars},
	}
	// The playbook of this repository resolves the collection of this repository, whatever the layer ansible.cfg holds.
	env := map[string]string{"ANSIBLE_COLLECTIONS_PATH": filepath.Join(p.AnsibleDir, "collections")}
	playbookFile := filepath.Join(p.AnsibleDir, "playbooks", "playbook_platform.yaml")
	if err := ansibleops.RunPlaybookWithConfig(ctx, filepath.Join(layerDir, "ansible.cfg"), layerDir, playbookFile, opts, env); err != nil {
		return fmt.Errorf("vaultops: Downstream Vault unseal playbook: %w", err)
	}
	out.Print(ui.OK, "[Downstream Vault] Unseal playbook execution completed.")
	return nil
}
