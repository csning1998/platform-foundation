package clusterops

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"platform/internal/operatorops"
)

const keycloakWrapper = "spire-fetch-example-platform-terraform-operator-keycloak-frontend"

// workstationFixture is a workstation whose terraform, kubectl, JWT-SVID wrapper, and Vault are test doubles.
type workstationFixture struct {
	ws      Workstation
	vault   *vaultFixture
	runtime string
	env     map[string]string
}

// operatorEntry returns one entry of output downstream_vault_operators.
func operatorEntry(service, component, vault string) map[string]any {
	return map[string]any{
		"auth_mount": "spire-parent-jwt-svid-provider",
		"role_name":  "example-platform-terraform-operator-" + service + "-" + component,
		"cluster_config": map[string]any{
			"vault": vault, "kv_mount": "secret", "kv_path": "example-platform/" + service + "/" + component + "/cluster-config",
		},
	}
}

// writeTenantsOutput writes the output of terraform output -json which points at the Vault double.
func writeTenantsOutput(t *testing.T, address, caFile string) string {
	t.Helper()
	outputs := map[string]any{
		"downstream_vault_endpoint":     map[string]any{"value": address},
		"downstream_vault_ca_cert_path": map[string]any{"value": caFile},
		"downstream_vault_operators": map[string]any{"value": map[string]any{
			"keycloak":         map[string]any{"frontend": operatorEntry("keycloak", "frontend", "downstream")},
			"vault-downstream": map[string]any{"frontend": operatorEntry("vault-downstream", "frontend", "bastion")},
			"harbor-origin":    map[string]any{"frontend": operatorEntry("harbor-origin", "frontend", "bastion")},
		}},
	}
	content, err := json.Marshal(outputs)
	if err != nil {
		t.Fatalf("marshal tenants output: %v", err)
	}
	path := filepath.Join(t.TempDir(), "output.json")
	err = os.WriteFile(path, content, 0o600)
	if err != nil {
		t.Fatalf("write tenants output: %v", err)
	}
	return path
}

func newWorkstationFixture(t *testing.T, kubectlBody string) *workstationFixture {
	t.Helper()
	f := &workstationFixture{
		vault: newVaultFixture(t, map[string]map[string]any{
			"example-platform/keycloak/frontend/cluster-config":         clusterConfigSecret(),
			"example-platform/vault-downstream/frontend/cluster-config": clusterConfigSecret(),
		}),
		runtime: t.TempDir(),
	}
	bin, wrappers := t.TempDir(), t.TempDir()
	writeExecutable(t, bin, "terraform", `cat "`+writeTenantsOutput(t, f.vault.server.URL, f.vault.caFile)+`"`)
	writeExecutable(t, bin, "kubectl", kubectlBody)
	writeExecutable(t, wrappers, keycloakWrapper, `printf '{"jwt":"eyJ.keycloak.sig"}'`)
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("GITLAB_TERRAFORM_STATE_BASE", testStateBase)

	certFile, keyFile := writeClientCertificate(t, "operator-platform-foundation")
	f.env = map[string]string{
		"XDG_RUNTIME_DIR":   f.runtime,
		"VAULT_ADDR":        f.vault.server.URL,
		"VAULT_TOKEN":       "s.tenant",
		"VAULT_CACERT":      f.vault.caFile,
		"VAULT_CLIENT_CERT": certFile,
		"VAULT_CLIENT_KEY":  keyFile,
	}
	f.ws = Workstation{
		TenantsLayerDir: "/repo/terraform/layers/security-vault-downstream-tenants",
		Operator:        operatorops.Config{WrapperDir: wrappers, OwnerCode: "example-platform"},
		Getenv:          func(key string) string { return f.env[key] },
	}
	return f
}

const reportNodes = `printf '172.16.130.200 '`

// assertRuntimeEmpty fails when a session directory remains below the runtime directory.
func (f *workstationFixture) assertRuntimeEmpty(t *testing.T) {
	t.Helper()
	entries, err := os.ReadDir(f.runtime)
	if err != nil || len(entries) != 0 {
		t.Errorf("runtime directory contains %v, %v, want no session directory", entries, err)
	}
}

func TestOpenSession_AuthenticatesOnDownstreamVault(t *testing.T) {
	f := newWorkstationFixture(t, reportNodes)

	session, err := f.ws.OpenSession(context.Background(), "keycloak/frontend")
	if err != nil {
		t.Fatalf("OpenSession: %v", err)
	}
	if filepath.Dir(session.Dir) != f.runtime || session.NodesErr != nil || !slices.Equal(session.Nodes, []string{"172.16.130.200"}) {
		t.Errorf("session = %+v, want a directory below %s with node 172.16.130.200", session, f.runtime)
	}
	assertFileContains(t, session.KubeconfigPath(), "kind: Config")
	assertFileContains(t, filepath.Join(session.Dir, "talosconfig"), "endpoints: [172.16.130.200]")

	// The login request omits a token. The tenant token of the Bastion Vault therefore never reaches the Downstream Vault.
	for _, want := range []string{
		"PUT /v1/auth/spire-parent-jwt-svid-provider/login token=",
		"GET /v1/secret/data/example-platform/keycloak/frontend/cluster-config token=s.downstream",
	} {
		if !slices.Contains(f.vault.recorded(), want) {
			t.Errorf("requests = %q, want %q", f.vault.recorded(), want)
		}
	}
}

func TestOpenSession_AuthenticatesOnBastionVault(t *testing.T) {
	f := newWorkstationFixture(t, reportNodes)

	_, err := f.ws.OpenSession(context.Background(), "vault-downstream/frontend")
	if err != nil {
		t.Fatalf("OpenSession: %v", err)
	}
	want := []string{"GET /v1/secret/data/example-platform/vault-downstream/frontend/cluster-config token=s.tenant"}
	if !slices.Equal(f.vault.recorded(), want) {
		t.Errorf("requests = %q, want %q alone", f.vault.recorded(), want)
	}
}

func TestOpenSession_RendersTalosconfigWithoutEndpointsWhenAPIServerUnreachable(t *testing.T) {
	f := newWorkstationFixture(t, `echo "Unable to connect to the server" >&2; exit 1`)

	session, err := f.ws.OpenSession(context.Background(), "keycloak/frontend")
	if err != nil {
		t.Fatalf("OpenSession: %v", err)
	}
	if session.NodesErr == nil || len(session.Nodes) != 0 {
		t.Errorf("session = %+v, want NodesErr and no nodes", session)
	}
	content, err := os.ReadFile(filepath.Join(session.Dir, "talosconfig"))
	if err != nil || strings.Contains(string(content), "endpoints:") {
		t.Errorf("talosconfig = %q, %v, want no endpoints", content, err)
	}
}

func TestOpenSession_FailsWithoutSessionFiles(t *testing.T) {
	cases := []struct {
		name    string
		arg     string
		prepare func(f *workstationFixture)
		want    error
	}{
		{"invalid argument", "keycloak", nil, ErrInvalidTarget},
		{"unknown target", "gitlab/praefect", nil, ErrUnknownTarget},
		{"absent leaf", "harbor-origin/frontend", nil, ErrClusterConfigMissing},
		{"absent wrapper", "keycloak/frontend", func(f *workstationFixture) { f.ws.Operator.WrapperDir = f.runtime }, operatorops.ErrWrapperMissing},
		{"no vault proxy environment", "vault-downstream/frontend", func(f *workstationFixture) { delete(f.env, "VAULT_TOKEN") }, ErrProxyEnvironmentMissing},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newWorkstationFixture(t, reportNodes)
			if c.prepare != nil {
				c.prepare(f)
			}
			_, err := f.ws.OpenSession(context.Background(), c.arg)
			if !errors.Is(err, c.want) {
				t.Errorf("OpenSession(%q) error = %v, want %v", c.arg, err, c.want)
			}
			f.assertRuntimeEmpty(t)
		})
	}
}

// TestCreateSession_RemovesDirectoryOnWriteFailure covers a talosconfig which already exists in the session directory.
func TestCreateSession_RemovesDirectoryOnWriteFailure(t *testing.T) {
	f := newWorkstationFixture(t, `touch "$(dirname "$2")/talosconfig"; printf '10.0.0.1 '`)

	_, err := f.ws.CreateSession(context.Background(), operatorops.OperatorSubject{Service: "keycloak", Component: "frontend"},
		Credential{Kubeconfig: []byte("kind: Config\n")})
	if err == nil {
		t.Fatal("CreateSession error = nil, want the talosconfig write failure")
	}
	f.assertRuntimeEmpty(t)
}

func TestCreateSession_FailsWithoutRuntimeDir(t *testing.T) {
	f := newWorkstationFixture(t, reportNodes)
	f.env["XDG_RUNTIME_DIR"] = filepath.Join(f.runtime, "absent")

	_, err := f.ws.CreateSession(context.Background(), operatorops.OperatorSubject{Service: "keycloak", Component: "frontend"}, Credential{})
	if err == nil {
		t.Error("CreateSession error = nil, want a failure below an absent runtime directory")
	}
}

func assertFileContains(t *testing.T, path, want string) {
	t.Helper()
	content, err := os.ReadFile(path)
	if err != nil || !strings.Contains(string(content), want) {
		t.Errorf("%s = %q, %v, want %q", filepath.Base(path), content, err, want)
	}
}
