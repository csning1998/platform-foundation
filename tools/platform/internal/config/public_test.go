package config

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// loadPublicTestEnv returns an Env of a .env file with a reference, a plain value, and a secret.
func loadPublicTestEnv(t *testing.T) *Env {
	t.Helper()
	path := filepath.Join(t.TempDir(), ".env")
	content := `PROJECT_ROOT="/repo/example-platform"
BASTION_VAULT_ADDR="https://127.0.0.1:8200"
BASTION_VAULT_CACERT="${PROJECT_ROOT}/../shared/tls/root.pem"
VAULT_TOKEN="hvs.secret-token-value"
`
	err := os.WriteFile(path, []byte(content), 0o600)
	if err != nil {
		t.Fatalf("write .env: %v", err)
	}
	e, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	return e
}

func TestResolvePublicValue_ResolvesAllowedKeys(t *testing.T) {
	e := loadPublicTestEnv(t)
	cases := []struct {
		key  string
		want string
	}{
		{KeyBastionVaultAddr, "https://127.0.0.1:8200"},
		{KeyBastionVaultCACert, "/repo/example-platform/../shared/tls/root.pem"},
		{KeyProjectRoot, "/repo/example-platform"},
	}
	for _, c := range cases {
		t.Run(c.key, func(t *testing.T) {
			got, err := e.ResolvePublicValue(c.key)
			if err != nil || got != c.want {
				t.Errorf("ResolvePublicValue(%s) = %q, %v, want %q, nil", c.key, got, err, c.want)
			}
		})
	}
}

func TestResolvePublicValue_RefusesSecretAndUndefinedKeys(t *testing.T) {
	e := loadPublicTestEnv(t)
	cases := []struct {
		key  string
		want error
	}{
		{KeyVaultToken, ErrSecretKey},
		{"SONAR_TOKEN", ErrKeyUndefined},
		{"", ErrKeyUndefined},
	}
	for _, c := range cases {
		t.Run(c.key, func(t *testing.T) {
			got, err := e.ResolvePublicValue(c.key)
			if !errors.Is(err, c.want) || got != "" {
				t.Fatalf("ResolvePublicValue(%q) = %q, %v, want \"\", %v", c.key, got, err, c.want)
			}
			if !strings.Contains(err.Error(), c.key) || strings.Contains(err.Error(), "secret-token-value") {
				t.Errorf("ResolvePublicValue(%q) error = %q, want the key and no value", c.key, err)
			}
		})
	}
}
