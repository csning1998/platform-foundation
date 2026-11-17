package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"platform/internal/config"
	"platform/internal/hostsops"
)

const hostsNetworkXML = `<network><dns><host ip='172.16.125.250'><hostname>example-platform-spire-parent.dev</hostname></host></dns></network>`

// hostsSyncConfig returns a sync configuration of a temporary hosts file which contains current.
func hostsSyncConfig(t *testing.T, current string, listErr error) hostsops.SyncConfig {
	t.Helper()
	path := filepath.Join(t.TempDir(), "hosts")
	err := os.WriteFile(path, []byte(current), 0o644)
	if err != nil {
		t.Fatalf("write hosts file: %v", err)
	}
	return hostsops.SyncConfig{
		Config:         hostsops.Config{HostsFile: path},
		Prefix:         "example-platform-",
		ListNetworkXML: func() ([]string, error) { return []string{hostsNetworkXML}, listErr },
	}
}

func TestSyncHosts_PrintsDiffAndAppliesChanges(t *testing.T) {
	current := hostsops.BeginMark + "\n172.16.125.250 example-platform-spire-parent.dev\n" + hostsops.EndMark + "\n"
	cases := []struct {
		name    string
		current string
		apply   bool
		want    []string
	}{
		{"dry run", "127.0.0.1 localhost\n", false, []string{"+172.16.125.250 example-platform-spire-parent.dev", "Dry run"}},
		{"apply", "127.0.0.1 localhost\n", true, []string{"+172.16.125.250 example-platform-spire-parent.dev", "backup at"}},
		{"already current", current, true, []string{"already matches"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			a, out := newOperationsApp(t, "")
			err := a.syncHosts(context.Background(), hostsSyncConfig(t, c.current, nil), c.apply)
			if err != nil {
				t.Fatalf("syncHosts: %v", err)
			}
			for _, want := range c.want {
				if !strings.Contains(out.String(), want) {
					t.Errorf("output = %q, want %q", out.String(), want)
				}
			}
		})
	}
}

func TestSyncHosts_ReturnsTheLibvirtFailure(t *testing.T) {
	a, _ := newOperationsApp(t, "")
	failure := errors.New("libvirt unavailable")
	err := a.syncHosts(context.Background(), hostsSyncConfig(t, "127.0.0.1 localhost\n", failure), false)
	if !errors.Is(err, failure) {
		t.Errorf("syncHosts error = %v, want %v", err, failure)
	}
}

func TestNewHostsSyncConfig_InitializesWithDefaults(t *testing.T) {
	cfg := newHostsSyncConfig()
	if cfg.HostsFile != "/etc/hosts" || len(cfg.Elevate) != 1 || cfg.Elevate[0] != "sudo" || cfg.Prefix != config.ProjectCode+"-" || cfg.ListNetworkXML == nil {
		t.Errorf("newHostsSyncConfig = %+v, want /etc/hosts through sudo with prefix %s-", cfg, config.ProjectCode)
	}
}
