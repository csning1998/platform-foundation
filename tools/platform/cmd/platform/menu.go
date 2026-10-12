package main

import (
	"context"
	"path/filepath"
	"strings"

	"platform/internal/clusterops"
	"platform/internal/config"
	"platform/internal/packerops"
	"platform/internal/ui"
	"platform/internal/vaultops"
)

type menuOption struct {
	label string
	run   func(ctx context.Context) error
}

// runMenu returns after dispatching the first valid selection. An invalid selection re-prompts instead of exiting.
func (a *app) runMenu(ctx context.Context) error {
	options := []menuOption{
		{"[Downstream] Unseal Downstream Vault via Ansible", func(ctx context.Context) error { return a.unsealDownstreamVault(ctx) }},
		{"Generate SSH Key", func(ctx context.Context) error { return a.sshKeygenMenu() }},
		{"Verify IaC Environment", func(ctx context.Context) error { return a.verifyEnvironment() }},
		{"Execute Hypervisor Configuration via Ansible", func(ctx context.Context) error { return a.runHypervisorPlaybook(ctx) }},
		{"Build Packer Base Image", func(ctx context.Context) error { return a.packerMenu(ctx) }},
		{"Verify Guest VM Connectivity via SSH", func(ctx context.Context) error { return a.sshVerifyMenu() }},
		{"Switch Environment Strategy", func(ctx context.Context) error { return a.switchStrategy() }},
		{"Purge All Packer Artifacts", func(ctx context.Context) error { return a.purgeAllPackerArtifacts() }},
		{"Purge All Infrastructure Resources (Libvirt + Terraform)", func(ctx context.Context) error { return a.purgeAllInfrastructure() }},
		{"Quit", nil},
	}

	a.out.Print(ui.Info, "======= Platform Management Executor =======")
	a.printEnvironmentBanner()
	a.out.PrintDivider("")

	env, err := config.BootstrapEnv(a.root, a.packerDir, a.terraform, a.out)
	if err != nil {
		return err
	}
	a.env = env

	a.printVaultStatusBanner(ctx)

	labels := make([]string, len(options))
	for i, opt := range options {
		labels[i] = opt.label
	}

	for {
		index, ok := a.out.PromptSelect(a.in, "Please select an action:", labels)
		if !ok {
			a.out.Print(ui.Error, "Invalid option")
			continue
		}
		chosen := options[index]
		if chosen.run == nil {
			a.out.Print(ui.Info, "Exiting.")
			return nil
		}
		return chosen.run(ctx)
	}
}

// printEnvironmentBanner reads root/.env directly since a.env remains unpopulated at this point.
func (a *app) printEnvironmentBanner() {
	strategy := config.StrategyNative
	if peeked, err := config.Load(filepath.Join(a.root, ".env")); err == nil {
		if s := peeked.Get(config.KeyEnvironmentStrategy); s != "" {
			strategy = s
		}
	}
	a.out.Print(ui.Info, "Environment: "+strings.ToUpper(strategy))
	if strategy == config.StrategyContainer {
		a.out.Print(ui.Info, "Engine: PODMAN")
	}
}

// printVaultStatusBanner reports the state of the Bastion Vault and the Downstream Vault.
func (a *app) printVaultStatusBanner(ctx context.Context) {
	a.out.PrintDivider("")

	bastion := vaultops.InspectBastionStatus(ctx, a.newVaultPaths())
	switch {
	case !bastion.Reachable:
		a.out.Print(ui.Error, "Bastion Vault: Stopped")
	case !bastion.Initialized:
		a.out.Print(ui.Warn, "Bastion Vault: Running (Not Initialized)")
	case bastion.Sealed:
		a.out.Print(ui.Warn, "Bastion Vault: Running (Sealed)")
	default:
		a.out.Print(ui.OK, "Bastion Vault: Running (Unsealed)")
	}

	tenantsLayerDir := a.newWorkstation().TenantsLayerDir
	coordinates, err := clusterops.ReadCoordinates(ctx, tenantsLayerDir)
	if err != nil {
		a.out.Print(ui.Warn, "Downstream Vault: Unknown (the outputs of "+filepath.Base(tenantsLayerDir)+" are unreadable)")
	} else {
		downstream := vaultops.InspectStatusAt(ctx, coordinates.Address, coordinates.CACertPath)
		switch {
		case !downstream.Reachable:
			a.out.Print(ui.Error, "Downstream Vault: Stopped or Unreachable")
		case downstream.Sealed:
			a.out.Print(ui.Warn, "Downstream Vault: Running (Sealed)")
		default:
			a.out.Print(ui.OK, "Downstream Vault: Running (Unsealed)")
		}
	}

	a.out.PrintDivider("")
}

func (a *app) sshKeygenMenu() error {
	name := a.out.PromptInput(a.in, "Enter the desired key name (default: id_ed25519_"+config.ProjectCode+"): ", "id_ed25519_"+config.ProjectCode)
	overwrite := true // The y/n overwrite prompt of the legacy bash script already gates entry to this path.
	return a.generateSSHKey(name, overwrite)
}

func (a *app) sshVerifyMenu() error {
	if !a.out.PromptConfirm(a.in, "Do you want to Verify Guest VM Connectivity via SSH connections? (y/n): ") {
		a.out.Print(ui.Info, "Skipping SSH verification.")
		return nil
	}
	return a.verifySSHConnectivity()
}

func (a *app) packerMenu(ctx context.Context) error {
	for {
		a.out.Print(ui.Info, "Select Packer category to build:")
		a.out.PrintDivider("")

		category, ok := a.out.PromptSelect(a.in, "Select a category:", []string{
			"Base OS Layers", "Service Layers", "Build ALL", "Back to Main Menu",
		})
		if !ok {
			a.out.Print(ui.Error, "Invalid option")
			continue
		}

		switch category {
		case 0:
			if done, err := a.packerCategoryMenu(ctx, "distro", "Base OS Images"); done {
				return err
			}
		case 1:
			if done, err := a.packerCategoryMenu(ctx, "services", "Service Images"); done {
				return err
			}
		case 2:
			return a.packerBuildAllMenu(ctx)
		case 3:
			return nil
		}
	}
}

// packerCategoryMenu reports done=true once a build ran or navigation exited since the loop of the caller stops on that signal.
func (a *app) packerCategoryMenu(ctx context.Context, subDir, title string) (done bool, err error) {
	var bases []string
	if subDir == "distro" {
		bases, err = packerops.ListDistroBases(a.packerDir)
	} else {
		bases, err = packerops.ListServiceBases(a.packerDir)
	}
	if err != nil {
		return true, err
	}

	labels := append(append([]string{}, bases...), "Build ALL in "+title, "Back")
	index, ok := a.out.PromptSelect(a.in, "Select "+title+":", labels)
	if !ok {
		a.out.Print(ui.Error, "Invalid option")
		return false, nil
	}

	switch {
	case index == len(labels)-1: // Back
		return false, nil
	case index == len(labels)-2: // Build ALL in <title>
		if subDir == "distro" {
			if err := packerops.Clean(a.packerDir, "all", nil, a.packerCache, a.out); err != nil {
				return true, err
			}
		}
		env, err := buildPackerExecutionEnv(ctx, a)
		if err != nil {
			return true, err
		}
		for _, b := range bases {
			if err := packerops.Clean(a.packerDir, b, nil, a.packerCache, a.out); err != nil {
				return true, err
			}
			if err := packerops.Build(ctx, a.packerDir, b, env, a.out); err != nil {
				return true, err
			}
		}
		return true, nil
	default:
		return true, a.buildPackerImage(ctx, bases[index])
	}
}

func (a *app) packerBuildAllMenu(ctx context.Context) error {
	if err := packerops.Clean(a.packerDir, "all", getConfiguredPackerBases(a.env), a.packerCache, a.out); err != nil {
		return err
	}

	env, err := buildPackerExecutionEnv(ctx, a)
	if err != nil {
		return err
	}

	distro, err := packerops.ListDistroBases(a.packerDir)
	if err != nil {
		return err
	}
	services, err := packerops.ListServiceBases(a.packerDir)
	if err != nil {
		return err
	}

	for _, b := range append(distro, services...) {
		if err := packerops.Build(ctx, a.packerDir, b, env, a.out); err != nil {
			return err
		}
	}
	return nil
}
