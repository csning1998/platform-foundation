package vaultops

import (
	"path/filepath"
	"testing"
)

func TestNewPaths_InitializesFieldsAndResolvesPaths(t *testing.T) {
	p := NewPaths("/root", "/ansible", "/tf", "/home/u", "https://bastion:8200", "/ca.pem")
	if p.ProjectRoot != "/root" || p.AnsibleDir != "/ansible" || p.TerraformDir != "/tf" || p.Home != "/home/u" {
		t.Errorf("NewPaths fields = %+v", p)
	}
	if p.bastionVaultAddr != "https://bastion:8200" || p.bastionVaultCACert != "/ca.pem" {
		t.Errorf("NewPaths Bastion fields = %q, %q, want https://bastion:8200, /ca.pem", p.bastionVaultAddr, p.bastionVaultCACert)
	}
}

func TestPaths_ResolvesHelperPaths(t *testing.T) {
	p := Paths{
		ProjectRoot:  "/root",
		AnsibleDir:   "/ansible",
		TerraformDir: "/tf",
		Home:         "/home/u",
	}

	want := filepath.FromSlash("/tf/layers/" + DownstreamLayer)
	if got := p.resolveDownstreamLayerDir(); got != want {
		t.Errorf("resolveDownstreamLayerDir = %q, want %q", got, want)
	}
}
