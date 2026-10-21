package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"platform/internal/config"
	"platform/internal/ui"
)

func newOperationsApp(t *testing.T, input string) (*app, *bytes.Buffer) {
	t.Helper()
	dir := t.TempDir()
	env, err := config.Load(filepath.Join(dir, ".env"))
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	var out bytes.Buffer
	a := &app{
		root:        dir,
		home:        dir,
		packerDir:   filepath.Join(dir, "packer"),
		packerCache: filepath.Join(dir, "cache"),
		terraform:   filepath.Join(dir, "terraform"),
		ansibleDir:  filepath.Join(dir, "ansible"),
		env:         env,
		out:         ui.New(&out, io.Discard),
		in:          bufio.NewReader(strings.NewReader(input)),

		readGuestCredentialEnv: fakeGuestCredentialEnv,
	}
	return a, &out
}

func TestBuildPackerExecutionEnv_DoesNotDuplicateNetVars(t *testing.T) {
	t.Setenv("VAULT_ADDR", "https://127.0.0.1:18211")
	dir := t.TempDir()
	env, err := config.Load(filepath.Join(dir, ".env"))
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	env.Set(config.KeyPKRVarNetBridge, "")
	env.Set(config.KeyPKRVarNetDevice, "virtio-net")

	a := &app{
		root:                   dir,
		home:                   dir,
		env:                    env,
		out:                    ui.New(io.Discard, io.Discard),
		readGuestCredentialEnv: fakeGuestCredentialEnv,
	}

	got, err := buildPackerExecutionEnv(context.Background(), a)
	if err != nil {
		t.Fatalf("buildPackerExecutionEnv: %v", err)
	}

	assertSingleEnvEntry(t, got, config.KeyPKRVarNetBridge, config.KeyPKRVarNetBridge+"=")
	assertSingleEnvEntry(t, got, config.KeyPKRVarNetDevice, config.KeyPKRVarNetDevice+"=virtio-net")
}

func TestBuildPackerImage_RejectsUnknownBaseAndPreservesStaleOutput(t *testing.T) {
	t.Setenv("VAULT_ADDR", "https://127.0.0.1:18211")
	dir := t.TempDir()
	packerDir := filepath.Join(dir, "packer")
	if err := os.MkdirAll(filepath.Join(packerDir, "distro"), 0o755); err != nil {
		t.Fatalf("mkdir distro: %v", err)
	}
	if err := os.WriteFile(filepath.Join(packerDir, "distro", "ubuntu-24.pkrvars.hcl"), nil, 0o644); err != nil {
		t.Fatalf("write var file: %v", err)
	}
	// Stale output left over under the typo'd name from a prior, since-renamed base. The var
	// file no longer exists, but Clean(base, ...) would still remove output/<base> unless
	// buildPackerImage validates the base first.
	staleOutputDir := filepath.Join(packerDir, "output", "ubuntu-25")
	if err := os.MkdirAll(staleOutputDir, 0o755); err != nil {
		t.Fatalf("mkdir stale output: %v", err)
	}
	if err := os.WriteFile(filepath.Join(staleOutputDir, "disk.qcow2"), []byte("fake"), 0o644); err != nil {
		t.Fatalf("write fake artifact: %v", err)
	}

	env, err := config.Load(filepath.Join(dir, ".env"))
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	a := &app{root: dir, home: dir, packerDir: packerDir, env: env, out: ui.New(io.Discard, io.Discard), readGuestCredentialEnv: fakeGuestCredentialEnv}

	err = a.buildPackerImage(context.Background(), "ubuntu-25")
	if err == nil || !strings.Contains(err.Error(), "unknown Packer base") {
		t.Fatalf("buildPackerImage(typo base) = %v, want error containing %q", err, "unknown Packer base")
	}

	if _, statErr := os.Stat(filepath.Join(staleOutputDir, "disk.qcow2")); statErr != nil {
		t.Errorf("stale output for the typo'd base was removed before validation: %v", statErr)
	}
}

func TestBuildPackerExecutionEnv_SetsExpectedNetVars(t *testing.T) {
	cases := []struct {
		name       string
		bridge     string
		device     string
		wantBridge string
		wantDevice string
	}{
		{"both empty", "", "", config.KeyPKRVarNetBridge + "=", config.KeyPKRVarNetDevice + "="},
		{"both set", "virbr0", "virtio-net", config.KeyPKRVarNetBridge + "=virbr0", config.KeyPKRVarNetDevice + "=virtio-net"},
		{"only device set", "", "e1000", config.KeyPKRVarNetBridge + "=", config.KeyPKRVarNetDevice + "=e1000"},
		{"only bridge set", "br1", "", config.KeyPKRVarNetBridge + "=br1", config.KeyPKRVarNetDevice + "="},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			env, err := config.Load(filepath.Join(dir, ".env"))
			if err != nil {
				t.Fatalf("config.Load: %v", err)
			}
			env.Set(config.KeyPKRVarNetBridge, c.bridge)
			env.Set(config.KeyPKRVarNetDevice, c.device)
			t.Setenv("VAULT_ADDR", "https://127.0.0.1:18211")
			t.Setenv("VAULT_CLIENT_CERT", "/example/client.pem")

			a := &app{root: dir, home: dir, env: env, out: ui.New(io.Discard, io.Discard), readGuestCredentialEnv: fakeGuestCredentialEnv}

			got, err := buildPackerExecutionEnv(context.Background(), a)
			if err != nil {
				t.Fatalf("buildPackerExecutionEnv: %v", err)
			}

			assertSingleEnvEntry(t, got, config.KeyPKRVarNetBridge, c.wantBridge)
			assertSingleEnvEntry(t, got, config.KeyPKRVarNetDevice, c.wantDevice)
			assertSingleEnvEntry(t, got, "VAULT_ADDR", "VAULT_ADDR=https://127.0.0.1:18211")
			assertSingleEnvEntry(t, got, "VAULT_CLIENT_CERT", "VAULT_CLIENT_CERT=/example/client.pem")
		})
	}
}

func TestBuildPackerExecutionEnv_RequiresTheVaultProxyEnvironment(t *testing.T) {
	dir := t.TempDir()
	env, err := config.Load(filepath.Join(dir, ".env"))
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	t.Setenv("VAULT_ADDR", "")
	a := &app{root: dir, home: dir, env: env, out: ui.New(io.Discard, io.Discard)}

	if _, err := buildPackerExecutionEnv(context.Background(), a); !errors.Is(err, errVaultProxyEnvironmentMissing) {
		t.Errorf("buildPackerExecutionEnv error = %v, want errVaultProxyEnvironmentMissing", err)
	}
}

func fakeGuestCredentialEnv(context.Context) ([]string, error) {
	return []string{"PKR_VAR_ssh_username=tester"}, nil
}

func TestBuildPackerExecutionEnv_AppendsTheGuestCredentials(t *testing.T) {
	t.Setenv("VAULT_ADDR", "https://127.0.0.1:18211")
	a, _ := newOperationsApp(t, "")
	a.readGuestCredentialEnv = fakeGuestCredentialEnv

	got, err := buildPackerExecutionEnv(context.Background(), a)
	if err != nil {
		t.Fatalf("buildPackerExecutionEnv: %v", err)
	}
	assertSingleEnvEntry(t, got, "PKR_VAR_ssh_username", "PKR_VAR_ssh_username=tester")
}

func TestBuildPackerExecutionEnv_PropagatesTheCredentialReadError(t *testing.T) {
	t.Setenv("VAULT_ADDR", "https://127.0.0.1:18211")
	a, _ := newOperationsApp(t, "")
	errRead := errors.New("read failed")
	a.readGuestCredentialEnv = func(context.Context) ([]string, error) { return nil, errRead }

	if _, err := buildPackerExecutionEnv(context.Background(), a); !errors.Is(err, errRead) {
		t.Errorf("buildPackerExecutionEnv error = %v, want %v", err, errRead)
	}
}

func assertSingleEnvEntry(t *testing.T, environ []string, key, want string) {
	t.Helper()
	var matches []string
	for _, kv := range environ {
		if strings.HasPrefix(kv, key+"=") {
			matches = append(matches, kv)
		}
	}
	if len(matches) != 1 {
		t.Fatalf("%s appears %d times in env, want exactly 1: %v", key, len(matches), matches)
	}
	if matches[0] != want {
		t.Errorf("%s = %q, want %q", key, matches[0], want)
	}
}

func TestAppendKVs_SkipsEntriesWithoutEquals(t *testing.T) {
	got := map[string]string{"keep": "yes"}
	appendKVs(got, []string{"A=1", "no-equals", "B=2", ""})
	if got["A"] != "1" || got["B"] != "2" || got["keep"] != "yes" {
		t.Errorf("appendKVs = %#v, want A=1 B=2 keep=yes", got)
	}
	if _, ok := got["no-equals"]; ok {
		t.Errorf("appendKVs stored an entry without '=': %#v", got)
	}
}

func TestAppendKVs_RejectsEmptyKey(t *testing.T) {
	got := map[string]string{"keep": "yes"}
	appendKVs(got, []string{"=empty-key-val", "VALID=123"})
	if _, ok := got[""]; ok {
		t.Errorf("appendKVs stored an entry with empty key: %#v", got)
	}
	if got["VALID"] != "123" || got["keep"] != "yes" {
		t.Errorf("appendKVs = %#v, want VALID=123 keep=yes", got)
	}
}

func TestConfirmExecution_HandlesAbortAndAccept(t *testing.T) {
	a, out := newOperationsApp(t, "n\n")
	if a.confirmExecution() {
		t.Fatal("confirmExecution(n) = true, want false")
	}
	if !strings.Contains(out.String(), operationAbortedMsg) {
		t.Errorf("output = %q, want it to contain %q", out.String(), operationAbortedMsg)
	}

	accepted, _ := newOperationsApp(t, "Y\n")
	if !accepted.confirmExecution() {
		t.Fatal("confirmExecution(Y) = false, want true")
	}
}

func TestPurgeLibvirtResources_AbortsWhenNotConfirmed(t *testing.T) {
	a, out := newOperationsApp(t, "n\n")
	if err := a.purgeLibvirtResources(); err != nil {
		t.Fatalf("purgeLibvirtResources abort: %v", err)
	}
	if !strings.Contains(out.String(), operationAbortedMsg) {
		t.Errorf("output = %q, want it to contain %q", out.String(), operationAbortedMsg)
	}
}

func TestPurgeAllInfrastructure_AbortsWhenNotConfirmed(t *testing.T) {
	a, out := newOperationsApp(t, "n\n")
	if err := a.purgeAllInfrastructure(); err != nil {
		t.Fatalf("purgeAllInfrastructure abort: %v", err)
	}
	if !strings.Contains(out.String(), operationAbortedMsg) {
		t.Errorf("output = %q, want it to contain %q", out.String(), operationAbortedMsg)
	}
}

func TestPurgeAllPackerArtifacts_RemovesPackerOutputArtifacts(t *testing.T) {
	a, _ := newOperationsApp(t, "")
	if err := os.MkdirAll(filepath.Join(a.packerDir, "output", "base-a"), 0o755); err != nil {
		t.Fatal(err)
	}
	a.env.Set(config.KeyAllPackerBases, "base-a")
	if err := a.purgeAllPackerArtifacts(); err != nil {
		t.Fatalf("purgeAllPackerArtifacts: %v", err)
	}
	if _, err := os.Stat(filepath.Join(a.packerDir, "output", "base-a")); !os.IsNotExist(err) {
		t.Errorf("base-a output still present after purgeAllPackerArtifacts: %v", err)
	}
}

func TestVerifySSHConnectivity_FailsWhenKeyMissing(t *testing.T) {
	a, _ := newOperationsApp(t, "")
	err := a.verifySSHConnectivity()
	if err == nil || !strings.Contains(err.Error(), "SSH_PRIVATE_KEY") {
		t.Fatalf("verifySSHConnectivity = %v, want error containing SSH_PRIVATE_KEY", err)
	}
}

func TestSwitchStrategy_TogglesNativeAndContainer(t *testing.T) {
	a, _ := newOperationsApp(t, "")
	a.env.Set(config.KeyEnvironmentStrategy, config.StrategyNative)
	if err := a.switchStrategy(); err != nil {
		t.Fatalf("switchStrategy native->container: %v", err)
	}
	if got := a.env.Get(config.KeyEnvironmentStrategy); got != config.StrategyContainer {
		t.Errorf("strategy = %q, want %q", got, config.StrategyContainer)
	}
	if got := a.env.Get(config.KeyPKRVarNetDevice); got != "virtio-net" {
		t.Errorf("PKR_VAR_NET_DEVICE = %q, want virtio-net", got)
	}

	if err := a.switchStrategy(); err != nil {
		t.Fatalf("switchStrategy container->native: %v", err)
	}
	if got := a.env.Get(config.KeyEnvironmentStrategy); got != config.StrategyNative {
		t.Errorf("strategy = %q, want %q", got, config.StrategyNative)
	}
}

func TestBuildPackerImage_CleansAndBuildsAllWhenEmpty(t *testing.T) {
	t.Setenv("VAULT_ADDR", "https://127.0.0.1:18211")
	a, _ := newOperationsApp(t, "")
	if err := os.MkdirAll(filepath.Join(a.packerDir, "distro"), 0o755); err != nil {
		t.Fatal(err)
	}
	err := a.buildPackerImage(context.Background(), "all")
	if err != nil {
		t.Fatalf("buildPackerImage(all) with no configured bases: %v", err)
	}
}

func TestBuildPackerImage_FailsWhenBaseVarFileMissing(t *testing.T) {
	t.Setenv("VAULT_ADDR", "https://127.0.0.1:18211")
	a, _ := newOperationsApp(t, "")
	if err := os.MkdirAll(filepath.Join(a.packerDir, "distro"), 0o755); err != nil {
		t.Fatal(err)
	}
	a.env.Set(config.KeyAllPackerBases, "missing-base")
	err := a.buildPackerImage(context.Background(), "all")
	if err == nil || !strings.Contains(err.Error(), "var file not found") {
		t.Fatalf("buildPackerImage(all, missing-base) = %v, want var file not found", err)
	}
}

func TestSwitchStrategy_FailsOnReadOnlyEnv(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("skipping read-only directory test when running as root")
	}
	a, _ := newOperationsApp(t, "")
	a.env.Set(config.KeyEnvironmentStrategy, config.StrategyNative)
	if err := os.Chmod(a.root, 0o500); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(a.root, 0o700) })
	if err := a.switchStrategy(); err == nil {
		t.Fatal("switchStrategy: want Save error on read-only root, got nil")
	}
}

func TestPrintEnvValue_PrintsExpandedValue(t *testing.T) {
	a, out := newOperationsApp(t, "")
	a.env.Set("BASTION_VAULT_ADDR", "https://127.0.0.1:8200")

	err := a.printEnvValue("BASTION_VAULT_ADDR")
	if err != nil || out.String() != "https://127.0.0.1:8200\n" {
		t.Errorf("printEnvValue = %q, %v, want the value and one newline", out.String(), err)
	}
}

func TestPrintEnvValue_RefusesSecretKey(t *testing.T) {
	a, out := newOperationsApp(t, "")
	a.env.Set("VAULT_TOKEN", "hvs.secret-token-value")

	err := a.printEnvValue("VAULT_TOKEN")
	if !errors.Is(err, config.ErrSecretKey) || out.Len() != 0 {
		t.Errorf("printEnvValue(VAULT_TOKEN) = %q, %v, want no output and ErrSecretKey", out.String(), err)
	}
}
