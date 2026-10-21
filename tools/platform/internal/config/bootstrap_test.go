package config

import (
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"platform/internal/ui"
)

func TestComputePackerNetConfig_ContainerStrategy(t *testing.T) {
	out := ui.New(io.Discard, io.Discard)
	cfg := ComputePackerNetConfig(StrategyContainer, out)
	if cfg.Bridge != "" {
		t.Errorf("container strategy Bridge = %q, want empty", cfg.Bridge)
	}
	if cfg.Device != "virtio-net" {
		t.Errorf("container strategy Device = %q, want virtio-net", cfg.Device)
	}
}

func TestComputePackerNetConfig_NativeAndUnknownStrategy(t *testing.T) {
	out := ui.New(io.Discard, io.Discard)
	for _, strategy := range []string{StrategyNative, "some-unrecognized-strategy"} {
		t.Run(strategy, func(t *testing.T) {
			cfg := ComputePackerNetConfig(strategy, out)
			if cfg.Device != "virtio-net" {
				t.Errorf("Device = %q, want virtio-net", cfg.Device)
			}
			if cfg.Bridge != "" && cfg.Bridge != "virbr0" {
				t.Errorf("Bridge = %q, want empty or virbr0", cfg.Bridge)
			}
		})
	}
}

func TestBootstrapEnv_FirstRunInitializesDefaults(t *testing.T) {
	root := t.TempDir()
	packerDir := filepath.Join(root, "packer")
	terraformDir := filepath.Join(root, "terraform")
	out := ui.New(io.Discard, io.Discard)

	e, err := BootstrapEnv(root, packerDir, terraformDir, out)
	if err != nil {
		t.Fatalf("BootstrapEnv: %v", err)
	}

	wantKeys := map[string]string{
		KeyProjectRoot:         root,
		KeyEnvironmentStrategy: "native",
		KeyAllPackerBases:      "",
		KeyAllTerraformLayers:  "",
		KeyUhome:               "${HOME}",
		KeyPKRVarNetDevice:     "virtio-net",
	}
	for key, want := range wantKeys {
		if got := e.Get(key); got != want {
			t.Errorf("Get(%q) = %q, want %q", key, got, want)
		}
	}
	if _, ok := e.values[KeyHostUID]; !ok {
		t.Error("HOST_UID not set on first run")
	}
	if _, ok := e.values[KeyHostGID]; !ok {
		t.Error("HOST_GID not set on first run")
	}
	if _, ok := e.values[KeyLibvirtGID]; !ok {
		t.Error("LIBVIRT_GID not set on first run")
	}
	if _, ok := e.values[KeyUname]; !ok {
		t.Error("UNAME not set on first run")
	}

	envPath := filepath.Join(root, ".env")
	if _, err := os.Stat(envPath); err != nil {
		t.Errorf(".env not written: %v", err)
	}
}

func TestBootstrapEnv_SecondRunPreservesCustomStrategyAndKeys(t *testing.T) {
	root := t.TempDir()
	packerDir := filepath.Join(root, "packer")
	terraformDir := filepath.Join(root, "terraform")
	envPath := filepath.Join(root, ".env")

	mustWriteFile(t, envPath, "ENVIRONMENT_STRATEGY=\"container\"\nCUSTOM_KEY=\"custom-value\"\n")

	out := ui.New(io.Discard, io.Discard)
	e, err := BootstrapEnv(root, packerDir, terraformDir, out)
	if err != nil {
		t.Fatalf("BootstrapEnv: %v", err)
	}

	if got := e.Get(KeyEnvironmentStrategy); got != "container" {
		t.Errorf("ENVIRONMENT_STRATEGY = %q, want container (must not be overwritten)", got)
	}
	if got := e.Get("CUSTOM_KEY"); got != "custom-value" {
		t.Errorf("CUSTOM_KEY = %q, want custom-value (unrelated key must survive)", got)
	}
	if got := e.Get(KeyProjectRoot); got != root {
		t.Errorf("PROJECT_ROOT = %q, want %q (must be refreshed)", got, root)
	}
	facts, err := DetectHostFacts()
	if err != nil {
		t.Fatalf("DetectHostFacts: %v", err)
	}
	if got := e.Get(KeyHostUID); got != strconv.Itoa(facts.CurrentUID) {
		t.Errorf("HOST_UID = %q, want %q (must be refreshed)", got, strconv.Itoa(facts.CurrentUID))
	}
	if got := e.Get(KeyHostGID); got != strconv.Itoa(facts.CurrentGID) {
		t.Errorf("HOST_GID = %q, want %q (must be refreshed)", got, strconv.Itoa(facts.CurrentGID))
	}
	if got := e.Get(KeyLibvirtGID); got != strconv.Itoa(facts.LibvirtGID) {
		t.Errorf("LIBVIRT_GID = %q, want %q (must be refreshed)", got, strconv.Itoa(facts.LibvirtGID))
	}
	// Container strategy forces PKR_VAR_NET_BRIDGE to empty regardless of host bridge state.
	if got := e.Get(KeyPKRVarNetBridge); got != "" {
		t.Errorf("PKR_VAR_NET_BRIDGE = %q, want empty under container strategy", got)
	}
	if got := e.Get(KeyPKRVarNetDevice); got != "virtio-net" {
		t.Errorf("PKR_VAR_NET_DEVICE = %q, want virtio-net", got)
	}
}

func TestBootstrapEnv_BackfillsMissingStrategyOnExistingFile(t *testing.T) {
	root := t.TempDir()
	packerDir := filepath.Join(root, "packer")
	terraformDir := filepath.Join(root, "terraform")
	envPath := filepath.Join(root, ".env")

	// An existing file with ENVIRONMENT_STRATEGY absent entirely still takes the
	// "else" branch (os.Stat succeeds), exercising the empty-strategy backfill.
	mustWriteFile(t, envPath, "SOME_OTHER_KEY=\"value\"\n")

	out := ui.New(io.Discard, io.Discard)
	e, err := BootstrapEnv(root, packerDir, terraformDir, out)
	if err != nil {
		t.Fatalf("BootstrapEnv: %v", err)
	}
	if got := e.Get(KeyEnvironmentStrategy); got != "native" {
		t.Errorf("ENVIRONMENT_STRATEGY = %q, want native (backfilled)", got)
	}
	if got := e.Get("SOME_OTHER_KEY"); got != "value" {
		t.Errorf("SOME_OTHER_KEY = %q, want value (unrelated key must survive)", got)
	}
}

func TestBootstrapEnv_LeavesUpstreamDefaultsOutOfEnv(t *testing.T) {
	root := t.TempDir()
	out := ui.New(io.Discard, io.Discard)
	e, err := BootstrapEnv(root, filepath.Join(root, "packer"), filepath.Join(root, "terraform"), out)
	if err != nil {
		t.Fatalf("BootstrapEnv: %v", err)
	}
	for _, key := range []string{KeyBastionVaultAddr, KeyBastionVaultCACert} {
		if v, ok := e.values[key]; ok {
			t.Errorf("BootstrapEnv wrote %s = %q, want the key absent", key, v)
		}
	}
	want := strings.Replace(DefaultBastionVaultCACert, "${PROJECT_ROOT}", root, 1)
	if got := e.GetExpandedOrDefault(KeyBastionVaultCACert, DefaultBastionVaultCACert); got != want {
		t.Errorf("default BASTION_VAULT_CACERT = %q, want %q", got, want)
	}
}
