package main

import (
	"github.com/spf13/cobra"

	"platform/internal/config"
	"platform/internal/libvirtops"
	"platform/internal/packerops"
	"platform/internal/terraformops"
)

func (a *app) vaultCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "vault", Short: "Bastion and Production Vault operations"}

	cmd.AddCommand(&cobra.Command{
		Use:   "status",
		Short: "Inspect Bastion and Production Vault reachability and seal status",
		RunE:  func(cmd *cobra.Command, args []string) error { return a.reportVaultStatus(cmd.Context()) },
	})
	cmd.AddCommand(&cobra.Command{
		Use:   "unseal-downstream",
		Short: "[Downstream] Unseal the Downstream Vault of the VM runtime via Ansible",
		RunE:  func(cmd *cobra.Command, args []string) error { return a.unsealDownstreamVault(cmd.Context()) },
	})

	return cmd
}

func (a *app) sshCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "ssh", Short: "SSH key and connectivity operations"}

	var keyName string
	var overwrite bool
	genCmd := &cobra.Command{
		Use:   "keygen",
		Short: "Generate an ed25519 SSH key for IaC automation",
		RunE:  func(cmd *cobra.Command, args []string) error { return a.generateSSHKey(keyName, overwrite) },
	}
	genCmd.Flags().StringVar(&keyName, "name", "id_ed25519_"+config.ProjectCode, "key file name under $HOME/.ssh")
	genCmd.Flags().BoolVar(&overwrite, "overwrite", false, "overwrite an existing key")
	cmd.AddCommand(genCmd)

	cmd.AddCommand(&cobra.Command{
		Use:   "verify",
		Short: "Verify guest VM connectivity via SSH",
		RunE:  func(cmd *cobra.Command, args []string) error { return a.verifySSHConnectivity() },
	})

	return cmd
}

func (a *app) envCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "env", Short: "Environment verification"}
	cmd.AddCommand(&cobra.Command{
		Use:   "verify",
		Short: "Verify the full native IaC environment (non-interactive)",
		RunE:  func(cmd *cobra.Command, args []string) error { return a.verifyEnvironment() },
	})
	cmd.AddCommand(&cobra.Command{
		Use:         "get <KEY>",
		Short:       "Print the expanded .env value of KEY alone, refusing a secret key",
		Args:        cobra.ExactArgs(1),
		Annotations: map[string]string{annotationStdoutPayload: "true"},
		RunE:        func(cmd *cobra.Command, args []string) error { return a.printEnvValue(args[0]) },
	})
	return cmd
}

func (a *app) packerCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "packer", Short: "Packer image build management"}

	cmd.AddCommand(&cobra.Command{
		Use:   "build <base>",
		Short: "Clean and build one Packer base (or 'all')",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return a.buildPackerImage(cmd.Context(), args[0])
		},
	})
	cmd.AddCommand(&cobra.Command{
		Use:   "clean <base|all>",
		Short: "Clean Packer output artifacts and host cache",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return packerops.Clean(a.packerDir, args[0], getConfiguredPackerBases(a.env), a.packerCache, a.out)
		},
	})
	cmd.AddCommand(&cobra.Command{
		Use:   "purge-all",
		Short: "Clean every discovered Packer base's output and the host cache",
		RunE:  func(cmd *cobra.Command, args []string) error { return a.purgeAllPackerArtifacts() },
	})

	return cmd
}

func (a *app) terraformCmd() *cobra.Command {
	return &cobra.Command{
		Use:                "terraform [terraform arguments]",
		Short:              "Run terraform in the current layer directory, with the JWT-SVID of the layer operator when the layer logs in with one",
		DisableFlagParsing: true,
		Annotations:        map[string]string{annotationSkipBootstrap: "true"},
		RunE:               func(cmd *cobra.Command, args []string) error { return a.runLayerTerraform(cmd.Context(), args) },
	}
}

func (a *app) layerCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "layer", Short: "Terraform layer artifact management"}
	cmd.AddCommand(&cobra.Command{
		Use:   "clean <layer|all>",
		Short: "Report Terraform artifact cleanup status for a layer (or 'all')",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return terraformops.ReportCleanupStatus(a.terraform, args[0], getConfiguredTerraformLayers(a.env), a.out)
		},
	})
	return cmd
}

func (a *app) hostsCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "hosts", Short: "Host name resolution of the workstation"}

	var apply bool
	syncCmd := &cobra.Command{
		Use:         "sync",
		Short:       "Print the diff of the " + config.ProjectCode + " block of /etc/hosts against the libvirt DNS records, and write it with --apply",
		Annotations: map[string]string{annotationSkipBootstrap: "true"},
		RunE: func(cmd *cobra.Command, args []string) error {
			return a.syncHosts(cmd.Context(), newHostsSyncConfig(), apply)
		},
	}
	syncCmd.Flags().BoolVar(&apply, "apply", false, "back up /etc/hosts and write the block through sudo")
	cmd.AddCommand(syncCmd)

	return cmd
}

func (a *app) clusterCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "cluster", Short: "Operator sessions on the Talos clusters, in the platform-foundation Vault Proxy environment"}
	skipBootstrap := map[string]string{annotationSkipBootstrap: "true"}

	cmd.AddCommand(&cobra.Command{
		Use:         "shell <service>/<component>",
		Short:       "Open a shell with KUBECONFIG and TALOSCONFIG of the cluster, removed on exit",
		Args:        cobra.ExactArgs(1),
		Annotations: skipBootstrap,
		RunE:        func(cmd *cobra.Command, args []string) error { return a.openClusterShell(cmd.Context(), args[0]) },
	})
	cmd.AddCommand(&cobra.Command{
		Use:         "status <service>/<component>|all",
		Short:       "Print the nodes and the pods of one cluster or of every cluster",
		Args:        cobra.ExactArgs(1),
		Annotations: skipBootstrap,
		RunE:        func(cmd *cobra.Command, args []string) error { return a.reportClusterStatus(cmd.Context(), args[0]) },
	})

	return cmd
}

func (a *app) libvirtCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "libvirt", Short: "libvirt/KVM resource management"}
	cmd.AddCommand(&cobra.Command{
		Use:   "ensure-services",
		Short: "Start any inactive libvirt daemon sockets",
		RunE:  func(cmd *cobra.Command, args []string) error { return libvirtops.EnsureServices(a.out) },
	})
	cmd.AddCommand(&cobra.Command{
		Use:   "purge",
		Short: "Destroy every libvirt VM/pool/network under the platform project code",
		RunE:  func(cmd *cobra.Command, args []string) error { return a.purgeLibvirtResources() },
	})
	return cmd
}

func (a *app) strategyCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "strategy", Short: "Guest-VM provisioning strategy"}
	cmd.AddCommand(&cobra.Command{
		Use:   "switch",
		Short: "Toggle ENVIRONMENT_STRATEGY between native and container",
		RunE:  func(cmd *cobra.Command, args []string) error { return a.switchStrategy() },
	})
	return cmd
}
