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
	if got := p.ProdCACertPath(); got != filepath.FromSlash("/tf/layers/shared-vault-frontend/tls/bootstrap-ca.crt") {
		t.Errorf("ProdCACertPath = %q", got)
	}
	if got := p.resolveBastionAddr(); got != "https://bastion:8200" {
		t.Errorf("resolveBastionAddr = %q, want https://bastion:8200", got)
	}
	if got := p.resolveCACertFile(); got != "/ca.pem" {
		t.Errorf("resolveCACertFile = %q, want /ca.pem", got)
	}
}

func TestPaths_ResolvesHelperPaths(t *testing.T) {
	p := Paths{
		ProjectRoot:        "/root",
		AnsibleDir:         "/ansible",
		TerraformDir:       "/tf",
		Home:               "/home/u",
		bastionVaultCACert: "/custom/ca.pem",
	}

	cases := []struct {
		name string
		got  string
		want string
	}{
		{"resolveTLSDir", p.resolveTLSDir(), "/root/vault/tls"},
		{"resolveRootTokenFile", p.resolveRootTokenFile(), "/home/u/.vault-token"},
		{"resolveCACertFile", p.resolveCACertFile(), "/custom/ca.pem"},
		{"prodCACert", p.resolveProdCACertFile(), "/tf/layers/shared-vault-frontend/tls/bootstrap-ca.crt"},
		{"resolveDownstreamLayerDir", p.resolveDownstreamLayerDir(), "/tf/layers/" + DownstreamLayer},
	}
	for _, c := range cases {
		want := filepath.FromSlash(c.want)
		if c.got != want {
			t.Errorf("%s = %q, want %q", c.name, c.got, want)
		}
	}

	pDefault := Paths{
		ProjectRoot: "/root",
	}
	if got := pDefault.resolveCACertFile(); got != filepath.FromSlash("/root/vault/tls/ca.pem") {
		t.Errorf("default resolveCACertFile = %q, want %q", got, "/root/vault/tls/ca.pem")
	}
}
