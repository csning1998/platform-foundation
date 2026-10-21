package vaultops

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/apenella/go-ansible/v2/pkg/playbook"

	"platform/internal/ansibleops"
	"platform/internal/config"
	"platform/internal/ui"
)

// DownstreamLayer names the layer which renders the inventory and the unseal variables of the Downstream Vault.
const DownstreamLayer = "platform-vault-downstream-frontend"

var (
	// ErrProxyEnvironmentMissing reports a shell without the environment of the platform-foundation Vault Proxy.
	ErrProxyEnvironmentMissing = errors.New("vaultops: VAULT_ADDR, VAULT_CACERT, VAULT_TOKEN, VAULT_CLIENT_CERT, or VAULT_CLIENT_KEY is empty, allow the .envrc with direnv allow or run eval \"$(vault-proxy-env " + config.VaultProxyIdentity + ")\"")
	// ErrDownstreamInventoryMissing reports a Downstream Vault without the inventory of the VM runtime.
	ErrDownstreamInventoryMissing = errors.New("vaultops: the Downstream Vault has no VM runtime inventory, apply " + DownstreamLayer + " first, and the Talos runtime unseals through transit without this command")
)

// proxyEnvironmentKeys lists the variables which the ambient login of utils_vault_operator_login and group_vars read.
var proxyEnvironmentKeys = []string{"VAULT_ADDR", "VAULT_CACERT", "VAULT_TOKEN", "VAULT_CLIENT_CERT", "VAULT_CLIENT_KEY"}

// DownstreamInventory is the inventory and the unseal variables file which the Downstream layer rendered.
type DownstreamInventory struct {
	Inventory  string
	UnsealVars string
}

// genericClusterOutput is the subset of the generic_cluster output of the Downstream layer which the unseal reads.
type genericClusterOutput struct {
	Enabled        bool   `json:"enabled"`
	InventoryPath  string `json:"ansible_inventory_path"`
	UnsealVarsPath string `json:"ansible_unseal_vars_path"`
}

func (p Paths) resolveDownstreamLayerDir() string {
	return filepath.Join(p.TerraformDir, "layers", DownstreamLayer)
}

// ReadDownstreamInventory runs terraform output -json generic_cluster in layerDir and decodes the result.
func ReadDownstreamInventory(ctx context.Context, layerDir string) (DownstreamInventory, error) {
	var stdout, stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, "terraform", "-chdir="+layerDir, "output", "-json", "generic_cluster")
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		return DownstreamInventory{}, fmt.Errorf("%w: terraform output of %s: %w: %s",
			ErrDownstreamInventoryMissing, filepath.Base(layerDir), err, strings.TrimSpace(stderr.String()))
	}
	return DecodeDownstreamInventory(stdout.Bytes())
}

// DecodeDownstreamInventory returns the inventory and the unseal variables file which the generic_cluster output names.
func DecodeDownstreamInventory(data []byte) (DownstreamInventory, error) {
	var out genericClusterOutput
	if err := json.Unmarshal(data, &out); err != nil {
		return DownstreamInventory{}, fmt.Errorf("vaultops: decode the generic_cluster output: %w", err)
	}
	if !out.Enabled || out.InventoryPath == "" || out.UnsealVarsPath == "" {
		return DownstreamInventory{}, ErrDownstreamInventoryMissing
	}
	inv := DownstreamInventory{Inventory: out.InventoryPath, UnsealVars: out.UnsealVarsPath}
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
	inv, err := ReadDownstreamInventory(ctx, p.resolveDownstreamLayerDir())
	if err != nil {
		return err
	}

	opts := &playbook.AnsiblePlaybookOptions{
		Inventory:     inv.Inventory,
		Tags:          "vault-unseal",
		ExtraVarsFile: []string{"@" + inv.UnsealVars},
	}
	playbookFile := filepath.Join(p.AnsibleDir, "playbooks", "playbook_platform.yaml")
	if err := ansibleops.RunPlaybook(ctx, p.AnsibleDir, p.AnsibleDir, playbookFile, opts); err != nil {
		return fmt.Errorf("vaultops: Downstream Vault unseal playbook: %w", err)
	}
	out.Print(ui.OK, "[Downstream Vault] Unseal playbook execution completed.")
	return nil
}
