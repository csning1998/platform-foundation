package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/apenella/go-ansible/v2/pkg/playbook"
	"gitlab.com/csning1998-lab/terraform/terraform-provider-sshclient/sshops"

	"platform/internal/ansibleops"
	"platform/internal/config"
	"platform/internal/libvirtops"
	"platform/internal/packerops"
	"platform/internal/terraformops"
	"platform/internal/ui"
	"platform/internal/vaultops"
)

// Operation handlers shared between Cobra command execution and interactive menu dispatching.

// sshLogger MUST adapt *ui.Printer to sshops.Logger because external modules
// cannot import internal platform UI packages.
type sshLogger struct{ p *ui.Printer }

func (l sshLogger) Print(level sshops.Level, msg string) {
	switch level {
	case sshops.Step:
		l.p.Print(ui.Step, msg)
	case sshops.Task:
		l.p.Print(ui.Task, msg)
	case sshops.Warn:
		l.p.Print(ui.Warn, msg)
	case sshops.Error:
		l.p.Print(ui.Error, msg)
	case sshops.OK:
		l.p.Print(ui.OK, msg)
	default:
		l.p.Print(ui.Info, msg)
	}
}

func (l sshLogger) PrintDivider(char string) { l.p.PrintDivider(char) }

func (a *app) reportVaultStatus(ctx context.Context) error {
	a.printVaultStatusBanner(ctx)
	bastion := vaultops.InspectBastionStatus(ctx, a.newVaultPaths())
	if !bastion.Reachable {
		return fmt.Errorf("bastion vault is unreachable at %s", a.resolveBastionVaultAddr())
	}
	return nil
}

func (a *app) unsealDownstreamVault(ctx context.Context) error {
	return vaultops.UnsealDownstream(ctx, a.newVaultPaths(), os.Getenv, a.out)
}

func (a *app) generateSSHKey(keyName string, overwrite bool) error {
	path, err := sshops.GenerateKey(a.home, keyName, "ed25519", overwrite, sshLogger{a.out})
	if err != nil {
		return err
	}
	a.env.Set(config.KeySSHPrivateKey, path)
	if err := a.env.Save(); err != nil {
		return err
	}
	a.out.Print(ui.Info, "In Terraform: ssh_private_key_path = \""+path+"\"")
	a.out.Print(ui.Info, "In Packer: ssh_public_key_path  = \""+path+".pub\"")
	return nil
}

func (a *app) verifySSHConnectivity() error {
	if !sshops.KeyExists(a.env.Get(config.KeySSHPrivateKey)) {
		return fmt.Errorf("SSH_PRIVATE_KEY not set or missing; execute 'platform ssh keygen' first")
	}
	return sshops.VerifyConnectivity(a.home, sshLogger{a.out})
}

func (a *app) verifyEnvironment() error {
	var missing []string
	group := ""
	for _, c := range config.VerifyNativeEnvironment() {
		if c.Group != group {
			a.out.Print(ui.Step, "Checking "+c.Group+"...")
			group = c.Group
		}
		if c.Installed {
			a.out.Print(ui.Info, c.Name+": Installed")
		} else {
			a.out.Print(ui.Warn, c.Name+": Missing")
			missing = append(missing, c.Name)
		}
	}
	a.out.PrintDivider("")
	if len(missing) > 0 {
		return fmt.Errorf("verification failed: missing required tools: %s", strings.Join(missing, ", "))
	}
	a.out.Print(ui.OK, "Verification successful: All required tools are installed.")
	return nil
}

const hypervisorInventoryYAML = "---\nall:\n  hosts:\n    localhost:\n      ansible_connection: local\n"

// runHypervisorPlaybook writes a throwaway inventory into a.ansibleDir. The implicit
// localhost inventory carries no directory against which Ansible resolves group_vars.
func (a *app) runHypervisorPlaybook(ctx context.Context) error {
	inventory, err := os.CreateTemp(a.ansibleDir, "inventory-hypervisor-baseline-*.yaml")
	if err != nil {
		return fmt.Errorf("ansible-playbook: create temporary inventory: %w", err)
	}
	defer func() { _ = os.Remove(inventory.Name()) }()

	if _, err := inventory.WriteString(hypervisorInventoryYAML); err != nil {
		_ = inventory.Close()
		return fmt.Errorf("ansible-playbook: write temporary inventory: %w", err)
	}
	if err := inventory.Close(); err != nil {
		return fmt.Errorf("ansible-playbook: close temporary inventory: %w", err)
	}

	target := filepath.Join("ansible", "playbooks", "playbook_hypervisor.yaml")
	opts := &playbook.AnsiblePlaybookOptions{
		AskBecomePass: true,
		Inventory:     inventory.Name(),
	}
	if err := ansibleops.RunPlaybook(ctx, a.ansibleDir, a.root, target, opts); err != nil {
		return fmt.Errorf("ansible-playbook: %w", err)
	}
	a.out.Print(ui.OK, "Hypervisor configuration applied.")
	return nil
}

func (a *app) purgeAllPackerArtifacts() error {
	return packerops.Clean(a.packerDir, "all", getConfiguredPackerBases(a.env), a.packerCache, a.out)
}

func (a *app) buildPackerImage(ctx context.Context, base string) error {
	env, err := buildPackerExecutionEnv(ctx, a)
	if err != nil {
		return err
	}

	if base == "all" {
		if err := packerops.Clean(a.packerDir, "all", getConfiguredPackerBases(a.env), a.packerCache, a.out); err != nil {
			return err
		}
		for _, b := range getConfiguredPackerBases(a.env) {
			if err := packerops.Build(ctx, a.packerDir, b, env, a.out); err != nil {
				return err
			}
		}
		return nil
	}

	if !packerops.BaseExists(a.packerDir, base) {
		return fmt.Errorf("buildPackerImage: unknown Packer base %q", base)
	}
	if err := packerops.Clean(a.packerDir, base, nil, a.packerCache, a.out); err != nil {
		return err
	}
	return packerops.Build(ctx, a.packerDir, base, env, a.out)
}

func appendKVs(target map[string]string, kvs []string) {
	for _, kv := range kvs {
		if k, v, ok := strings.Cut(kv, "="); ok && k != "" {
			target[k] = v
		}
	}
}

// errVaultProxyEnvironmentMissing reports a shell which has not loaded the environment of the platform-foundation Vault Proxy.
var errVaultProxyEnvironmentMissing = errors.New(`VAULT_ADDR is empty: allow the .envrc with direnv allow, or run eval "$(vault-proxy-env ` + config.VaultProxyIdentity + `)"`)

// buildPackerExecutionEnv hands Packer the environment of the platform-foundation Vault Proxy, which the vault()
// function of the templates reads, and the variables of .env.
func buildPackerExecutionEnv(_ context.Context, a *app) ([]string, error) {
	if os.Getenv("VAULT_ADDR") == "" {
		return nil, errVaultProxyEnvironmentMissing
	}
	merged := make(map[string]string)
	appendKVs(merged, os.Environ())
	appendKVs(merged, a.env.Environ())

	out := make([]string, 0, len(merged))
	for k, v := range merged {
		out = append(out, k+"="+v)
	}
	return out, nil
}

const (
	confirmExecutionPrompt = "Type 'Y' or 'y' to confirm execution: "
	operationAbortedMsg    = "Operation aborted by user."
)

func (a *app) confirmExecution() bool {
	if a.out.PromptConfirm(a.in, confirmExecutionPrompt) {
		return true
	}
	a.out.Print(ui.Info, operationAbortedMsg)
	return false
}

func (a *app) purgeLibvirtResources() error {
	if !a.confirmExecution() {
		return nil
	}
	if err := libvirtops.EnsureServices(a.out); err != nil {
		return err
	}
	return libvirtops.Purge(a.out)
}

func (a *app) purgeAllInfrastructure() error {
	if !a.confirmExecution() {
		return nil
	}
	if err := libvirtops.EnsureServices(a.out); err != nil {
		return err
	}
	if err := libvirtops.Purge(a.out); err != nil {
		return err
	}
	return terraformops.ReportCleanupStatus(a.terraform, "all", getConfiguredTerraformLayers(a.env), a.out)
}

func (a *app) switchStrategy() error {
	a.out.Print(ui.Info, "Switching strategy...")
	a.out.Print(ui.Info, "Cleaning Terraform plugins/cache (keeping state)...")
	_ = os.RemoveAll(filepath.Join(a.terraform, ".terraform"))
	_ = os.Remove(filepath.Join(a.terraform, ".terraform.lock.hcl"))
	a.out.PrintDivider("")

	next := config.StrategyContainer
	if a.env.Get(config.KeyEnvironmentStrategy) == config.StrategyContainer {
		next = config.StrategyNative
	}
	net := config.ComputePackerNetConfig(next, a.out)
	a.env.Set(config.KeyPKRVarNetBridge, net.Bridge)
	a.env.Set(config.KeyPKRVarNetDevice, net.Device)
	a.env.Set(config.KeyEnvironmentStrategy, next)
	if err := a.env.Save(); err != nil {
		return err
	}
	a.out.Print(ui.Info, "Strategy 'ENVIRONMENT_STRATEGY' in .env updated to '"+next+"'.")
	return nil
}

// printEnvValue prints the expanded .env value of key alone on standard output.
func (a *app) printEnvValue(key string) error {
	value, err := a.env.ResolvePublicValue(key)
	if err != nil {
		return err
	}
	a.out.PrintText(value + "\n")
	return nil
}
