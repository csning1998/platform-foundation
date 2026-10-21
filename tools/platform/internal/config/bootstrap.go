package config

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"platform/internal/ui"
)

// PackerNetConfig defines network interface parameters (PKR_VAR_NET_BRIDGE and PKR_VAR_NET_DEVICE)
// for Packer execution environments.
type PackerNetConfig struct {
	Bridge string
	Device string
}

// ComputePackerNetConfig determines Packer network device and bridge settings based on strategy type
// and virbr0 interface availability. Container strategy forces user-mode (SLIRP) networking.
func ComputePackerNetConfig(strategy string, out *ui.Printer) PackerNetConfig {
	cfg := PackerNetConfig{Device: "virtio-net"}
	if strategy == StrategyContainer {
		out.Print(ui.Warn, "Container strategy detected. Forcing User Mode Networking (SLIRP) for Packer.")
		return cfg
	}
	if exec.Command("ip", "link", "show", "virbr0").Run() == nil {
		cfg.Bridge = "virbr0"
		out.Print(ui.Info, "Network Mode: Bridge detected (virbr0). Using performance networking.")
	} else {
		out.Print(ui.Warn, "'virbr0' bridge not found. Defaulting to user-mode/SLIRP networking.")
	}
	return cfg
}

// BootstrapEnv initializes or updates root/.env with default settings, host facts, and
// dynamically discovered infrastructure layers.
func BootstrapEnv(root, packerDir, terraformDir string, out *ui.Printer) (*Env, error) {
	envPath := filepath.Join(root, ".env")
	facts, err := DetectHostFacts()
	if err != nil {
		return nil, err
	}

	e, err := Load(envPath)
	if err != nil {
		return nil, err
	}

	if _, statErr := os.Stat(envPath); os.IsNotExist(statErr) {
		out.Print(ui.Info, "Creating new .env file...")
		for _, kv := range [][2]string{
			{KeyProjectRoot, root},
			{KeyEnvironmentStrategy, StrategyNative},
			{KeyAllPackerBases, ""},
			{KeyAllTerraformLayers, ""},
			{KeyHostUID, strconv.Itoa(facts.CurrentUID)},
			{KeyHostGID, strconv.Itoa(facts.CurrentGID)},
			{KeyUname, facts.CurrentUname},
			{KeyUhome, "${HOME}"},
			{KeyPKRVarNetBridge, ""},
			{KeyPKRVarNetDevice, "virtio-net"},
			{KeyLibvirtGID, strconv.Itoa(facts.LibvirtGID)},
		} {
			e.Set(kv[0], kv[1])
		}
	} else {
		e.Set(KeyHostUID, strconv.Itoa(facts.CurrentUID))
		e.Set(KeyHostGID, strconv.Itoa(facts.CurrentGID))
		e.Set(KeyProjectRoot, root)
		e.Set(KeyLibvirtGID, strconv.Itoa(facts.LibvirtGID))
		if e.Get(KeyEnvironmentStrategy) == "" {
			e.Set(KeyEnvironmentStrategy, StrategyNative)
		}
	}

	packerBases, err := DiscoverPackerBases(packerDir)
	if err != nil {
		return nil, err
	}
	e.Set(KeyAllPackerBases, strings.Join(packerBases, " "))

	tfLayers, err := DiscoverTerraformLayers(terraformDir)
	if err != nil {
		return nil, err
	}
	e.Set(KeyAllTerraformLayers, strings.Join(tfLayers, " "))

	strategy := e.Get(KeyEnvironmentStrategy)
	if strategy == "" {
		strategy = StrategyNative
	}
	net := ComputePackerNetConfig(strategy, out)
	e.Set(KeyPKRVarNetBridge, net.Bridge)
	e.Set(KeyPKRVarNetDevice, net.Device)

	if err := e.Save(); err != nil {
		return nil, err
	}
	return e, nil
}
