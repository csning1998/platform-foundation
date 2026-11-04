package sshclientops

import (
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"platform/internal/config"
	"platform/internal/ui"
)

// writeSSHFixture writes files under home/.ssh and returns the .ssh directory.
func writeSSHFixture(t *testing.T, home string, files map[string]string) string {
	t.Helper()
	sshDir := filepath.Join(home, ".ssh")
	if err := os.MkdirAll(sshDir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(sshDir, name), []byte(content), 0o600); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	return sshDir
}

func listNames(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read dir: %v", err)
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	return names
}

func TestPurge_RemovesClusterMaterialAndKeepsTheSharedGuestKey(t *testing.T) {
	home := t.TempDir()
	pc := config.ProjectCode
	sshDir := writeSSHFixture(t, home, map[string]string{
		"id_ed25519_" + pc + "-alpha":     "key",
		"id_ed25519_" + pc + "-alpha.pub": "pub",
		"id_rsa_" + pc + "-beta":          "key",
		"ssh_" + pc + "-alpha":            "Host alpha",
		"known_hosts_" + pc + "-alpha":    "alpha key",
		"id_ed25519_" + pc:                "shared key",
		"id_ed25519_" + pc + ".pub":       "shared pub",
		"id_ed25519_other-project-alpha":  "foreign key",
		"known_hosts":                     "global",
	})

	if err := Purge(home, ui.New(io.Discard, io.Discard)); err != nil {
		t.Fatalf("Purge: %v", err)
	}
	want := []string{"id_ed25519_" + pc, "id_ed25519_" + pc + ".pub", "id_ed25519_other-project-alpha", "known_hosts"}
	got := listNames(t, sshDir)
	slices.Sort(want)
	slices.Sort(got)
	if !slices.Equal(got, want) {
		t.Errorf("remaining files = %v, want %v", got, want)
	}
}

func TestPurge_RemovesIncludeDirectivesOfClustersEvenWithoutTheHostBlockFile(t *testing.T) {
	home := t.TempDir()
	sshDir := filepath.Join(home, ".ssh")
	clusterInclude := "Include " + filepath.Join(sshDir, "ssh_"+config.ProjectCode+"-alpha")
	foreignInclude := "Include " + filepath.Join(sshDir, "ssh_other-project-alpha")
	writeSSHFixture(t, home, map[string]string{
		"config": clusterInclude + "\n" + foreignInclude + "\nHost example\n    User tester\n",
	})

	if err := Purge(home, ui.New(io.Discard, io.Discard)); err != nil {
		t.Fatalf("Purge: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(sshDir, "config"))
	if err != nil {
		t.Fatalf("read config: %v", err)
	}
	if strings.Contains(string(data), clusterInclude) {
		t.Errorf("config still holds %q", clusterInclude)
	}
	if !strings.Contains(string(data), foreignInclude) || !strings.Contains(string(data), "Host example") {
		t.Errorf("config lost content outside the clusters of this repository:\n%s", data)
	}
}

func TestPurge_SucceedsWithoutSSHDirectory(t *testing.T) {
	if err := Purge(t.TempDir(), ui.New(io.Discard, io.Discard)); err != nil {
		t.Errorf("Purge: %v", err)
	}
}

func TestPurge_FailsWhenTheConfigIsUnreadable(t *testing.T) {
	home := t.TempDir()
	sshDir := writeSSHFixture(t, home, nil)
	if err := os.Mkdir(filepath.Join(sshDir, "config"), 0o700); err != nil {
		t.Fatalf("mkdir config: %v", err)
	}
	if err := Purge(home, ui.New(io.Discard, io.Discard)); err == nil {
		t.Error("Purge() error = nil, want the failure to read a config which is a directory")
	}
}

func TestPurge_FailsWhenTheSSHDirectoryIsUnlistable(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("skipping unreadable directory test when running as root")
	}
	home := t.TempDir()
	sshDir := writeSSHFixture(t, home, map[string]string{"config": "Host example\n"})
	if err := os.Chmod(sshDir, 0o300); err != nil {
		t.Fatalf("chmod: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(sshDir, 0o700) })
	if err := Purge(home, ui.New(io.Discard, io.Discard)); err == nil {
		t.Error("Purge() error = nil, want the failure to list an unreadable .ssh directory")
	}
}

func TestPurge_FailsWhenAClusterFileCannotBeRemoved(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("skipping read-only directory test when running as root")
	}
	home := t.TempDir()
	sshDir := writeSSHFixture(t, home, map[string]string{"ssh_" + config.ProjectCode + "-example": "Host example\n"})
	if err := os.Chmod(sshDir, 0o500); err != nil {
		t.Fatalf("chmod: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(sshDir, 0o700) })
	if err := Purge(home, ui.New(io.Discard, io.Discard)); err == nil {
		t.Error("Purge() error = nil, want the failure to remove a file in a read-only .ssh directory")
	}
}
