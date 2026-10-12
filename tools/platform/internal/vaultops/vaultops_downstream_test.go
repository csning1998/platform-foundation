package vaultops

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolveDownstreamInventory_RequiresTheLayerConfig(t *testing.T) {
	if _, err := ResolveDownstreamInventory(t.TempDir()); !errors.Is(err, ErrDownstreamInventoryMissing) {
		t.Errorf("ResolveDownstreamInventory error = %v, want ErrDownstreamInventoryMissing", err)
	}
}

func TestResolveDownstreamInventory_RequiresAnInventoryLine(t *testing.T) {
	layerDir := t.TempDir()
	writeFile(t, filepath.Join(layerDir, "ansible.cfg"), "[defaults]\nroles_path = /roles\n")
	if _, err := ResolveDownstreamInventory(layerDir); !errors.Is(err, ErrDownstreamInventoryMissing) {
		t.Errorf("ResolveDownstreamInventory error = %v, want ErrDownstreamInventoryMissing", err)
	}
}

func TestResolveDownstreamInventory_RequiresTheUnsealVariables(t *testing.T) {
	layerDir, ansibleDir := t.TempDir(), t.TempDir()
	inventory := filepath.Join(ansibleDir, "inventory-example-vault-downstream-frontend.yaml")
	writeFile(t, inventory, "---\n")
	writeFile(t, filepath.Join(layerDir, "ansible.cfg"), "[defaults]\ninventory = "+inventory+"\n")
	if _, err := ResolveDownstreamInventory(layerDir); !errors.Is(err, ErrDownstreamInventoryMissing) {
		t.Errorf("ResolveDownstreamInventory error = %v, want ErrDownstreamInventoryMissing", err)
	}
}

func TestResolveDownstreamInventory_DerivesTheUnsealVariables(t *testing.T) {
	layerDir, ansibleDir := t.TempDir(), t.TempDir()
	inventory := filepath.Join(ansibleDir, "inventory-example-vault-downstream-frontend.yaml")
	unsealVars := filepath.Join(ansibleDir, "inventory-example-vault-downstream-frontend-unseal-vars.json")
	writeFile(t, inventory, "---\n")
	writeFile(t, unsealVars, "{}")
	writeFile(t, filepath.Join(layerDir, "ansible.cfg"), "[defaults]\nroles_path = /roles\ninventory = "+inventory+"\n")

	got, err := ResolveDownstreamInventory(layerDir)
	if err != nil {
		t.Fatalf("ResolveDownstreamInventory: %v", err)
	}
	if got.Inventory != inventory || got.UnsealVars != unsealVars {
		t.Errorf("ResolveDownstreamInventory = %+v, want inventory %s and unseal variables %s", got, inventory, unsealVars)
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

func TestUnsealDownstream_RunsTheUnsealTagUnderTheLayerConfig(t *testing.T) {
	p := Paths{AnsibleDir: t.TempDir(), TerraformDir: t.TempDir()}
	layerDir := p.resolveDownstreamLayerDir()
	inventory := filepath.Join(p.AnsibleDir, "inventory-example-vault-downstream-frontend.yaml")
	unsealVars := filepath.Join(p.AnsibleDir, "inventory-example-vault-downstream-frontend-unseal-vars.json")
	writeFile(t, inventory, "---\n")
	writeFile(t, unsealVars, "{}")
	writeFile(t, filepath.Join(layerDir, "ansible.cfg"), "[defaults]\ninventory = "+inventory+"\n")
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
		"ANSIBLE_CONFIG=" + filepath.Join(layerDir, "ansible.cfg"),
		"ANSIBLE_COLLECTIONS_PATH=" + filepath.Join(p.AnsibleDir, "collections"),
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
		"echo \"ANSIBLE_CONFIG=$ANSIBLE_CONFIG\" >> " + record + "\n" +
		"echo \"ANSIBLE_COLLECTIONS_PATH=$ANSIBLE_COLLECTIONS_PATH\" >> " + record + "\n"
	if err := os.WriteFile(filepath.Join(bin, "ansible-playbook"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	return record
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
