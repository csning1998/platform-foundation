package vaultops

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestDecodeDownstreamInventory_RequiresTheGenericRuntime(t *testing.T) {
	data := []byte(`{"enabled":false,"ansible_inventory_path":null,"ansible_unseal_vars_path":null}`)
	if _, err := DecodeDownstreamInventory(data); !errors.Is(err, ErrDownstreamInventoryMissing) {
		t.Errorf("DecodeDownstreamInventory error = %v, want ErrDownstreamInventoryMissing", err)
	}
}

func TestDecodeDownstreamInventory_RequiresTheUnsealVariables(t *testing.T) {
	ansibleDir := t.TempDir()
	inventory := filepath.Join(ansibleDir, "inventory-example-vault-downstream-frontend.yaml")
	unsealVars := filepath.Join(ansibleDir, "inventory-example-vault-downstream-frontend-unseal-vars.json")
	writeFile(t, inventory, "---\n")
	if _, err := DecodeDownstreamInventory(buildGenericClusterOutput(inventory, unsealVars)); !errors.Is(err, ErrDownstreamInventoryMissing) {
		t.Errorf("DecodeDownstreamInventory error = %v, want ErrDownstreamInventoryMissing", err)
	}
}

func TestDecodeDownstreamInventory_ReturnsThePublishedPaths(t *testing.T) {
	ansibleDir := t.TempDir()
	inventory := filepath.Join(ansibleDir, "inventory-example-vault-downstream-frontend.yaml")
	unsealVars := filepath.Join(ansibleDir, "inventory-example-vault-downstream-frontend-unseal-vars.json")
	writeFile(t, inventory, "---\n")
	writeFile(t, unsealVars, "{}")

	got, err := DecodeDownstreamInventory(buildGenericClusterOutput(inventory, unsealVars))
	if err != nil {
		t.Fatalf("DecodeDownstreamInventory: %v", err)
	}
	if got.Inventory != inventory || got.UnsealVars != unsealVars {
		t.Errorf("DecodeDownstreamInventory = %+v, want inventory %s and unseal variables %s", got, inventory, unsealVars)
	}
}

func TestReadDownstreamInventory_RequiresTheLayerOutput(t *testing.T) {
	installFakeTerraform(t, "", 1)
	if _, err := ReadDownstreamInventory(context.Background(), t.TempDir()); !errors.Is(err, ErrDownstreamInventoryMissing) {
		t.Errorf("ReadDownstreamInventory error = %v, want ErrDownstreamInventoryMissing", err)
	}
}

func TestUnsealDownstream_RequiresTheProxyEnvironment(t *testing.T) {
	env := fullProxyEnvironment()
	delete(env, "VAULT_CLIENT_KEY")
	err := UnsealDownstream(context.Background(), Paths{TerraformDir: t.TempDir()}, mapGetenv(env), discardOut())
	if !errors.Is(err, ErrProxyEnvironmentMissing) {
		t.Errorf("UnsealDownstream error = %v, want ErrProxyEnvironmentMissing", err)
	}
}

func TestUnsealDownstream_RunsTheUnsealTagUnderTheRepositoryConfig(t *testing.T) {
	p := Paths{AnsibleDir: t.TempDir(), TerraformDir: t.TempDir()}
	inventory := filepath.Join(p.AnsibleDir, "inventory-example-vault-downstream-frontend.yaml")
	unsealVars := filepath.Join(p.AnsibleDir, "inventory-example-vault-downstream-frontend-unseal-vars.json")
	writeFile(t, inventory, "---\n")
	writeFile(t, unsealVars, "{}")
	installFakeTerraform(t, string(buildGenericClusterOutput(inventory, unsealVars)), 0)
	record := installFakeAnsiblePlaybook(t)

	if err := UnsealDownstream(context.Background(), p, mapGetenv(fullProxyEnvironment()), discardOut()); err != nil {
		t.Fatalf("UnsealDownstream: %v", err)
	}
	data, err := os.ReadFile(record)
	if err != nil {
		t.Fatal(err)
	}
	got := string(data)
	for _, want := range []string{
		"--tags=vault-unseal",
		"--extra-vars=@" + unsealVars,
		"--inventory=" + inventory,
		filepath.Join(p.AnsibleDir, "playbooks", "playbook_platform.yaml"),
		"ANSIBLE_CONFIG=" + filepath.Join(p.AnsibleDir, "ansible.cfg"),
	} {
		if !strings.Contains(got, want) {
			t.Errorf("ansible-playbook record lacks %q:\n%s", want, got)
		}
	}
}

func fullProxyEnvironment() map[string]string {
	env := map[string]string{}
	for _, key := range proxyEnvironmentKeys {
		env[key] = "example"
	}
	return env
}

func mapGetenv(env map[string]string) func(string) string {
	return func(key string) string { return env[key] }
}

// installFakeAnsiblePlaybook puts a recorder of the arguments and the configuration variables first on PATH.
func installFakeAnsiblePlaybook(t *testing.T) string {
	t.Helper()
	bin := t.TempDir()
	record := filepath.Join(t.TempDir(), "record")
	script := "#!/bin/sh\n" +
		"echo \"$*\" >> " + record + "\n" +
		"echo \"ANSIBLE_CONFIG=$ANSIBLE_CONFIG\" >> " + record + "\n"
	if err := os.WriteFile(filepath.Join(bin, "ansible-playbook"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	return record
}

// installFakeTerraform puts first on PATH a terraform which prints stdout and exits with code.
func installFakeTerraform(t *testing.T, stdout string, code int) {
	t.Helper()
	bin := t.TempDir()
	payload := filepath.Join(t.TempDir(), "stdout")
	writeFile(t, payload, stdout)
	script := "#!/bin/sh\ncat " + payload + "\nexit " + strconv.Itoa(code) + "\n"
	if err := os.WriteFile(filepath.Join(bin, "terraform"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func buildGenericClusterOutput(inventory, unsealVars string) []byte {
	return []byte(`{"enabled":true,"ansible_inventory_path":"` + inventory + `","ansible_unseal_vars_path":"` + unsealVars + `"}`)
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}
