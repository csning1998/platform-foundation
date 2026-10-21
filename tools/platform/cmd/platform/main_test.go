package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"platform/internal/config"
	"platform/internal/ui"
)

func TestSplitWhitespaceFields_SplitsWhitespace(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want []string
	}{
		{"empty", "", nil},
		{"only spaces", "   ", nil},
		{"single field", "a", []string{"a"}},
		{"two fields", "a b", []string{"a", "b"}},
		{"consecutive spaces", "a  b", []string{"a", "b"}},
		{"tab separator", "a\tb", []string{"a", "b"}},
		{"leading and trailing spaces", " a b ", []string{"a", "b"}},
		{"newline not a separator", "a\nb", []string{"a\nb"}},
		{"mixed tabs and spaces", "a\t \tb", []string{"a", "b"}},
		{"single space char", " ", nil},
		{"unicode content", "café latte", []string{"café", "latte"}},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			assertSplitWhitespaceFields(t, c.in, c.want)
		})
	}
}

func assertSplitWhitespaceFields(t *testing.T, in string, want []string) {
	t.Helper()
	got := splitWhitespaceFields(in)
	if len(want) == 0 {
		if len(got) != 0 {
			t.Fatalf("splitWhitespaceFields(%q) = %#v, want empty", in, got)
		}
		return
	}
	if len(got) != len(want) {
		t.Fatalf("splitWhitespaceFields(%q) = %#v, want %#v", in, got, want)
	}
	for i := range got {
		if got[i] != want[i] {
			t.Fatalf("splitWhitespaceFields(%q) = %#v, want %#v", in, got, want)
		}
	}
}

func loadTestEnv(t *testing.T, content string) *config.Env {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, ".env")
	if content != "" {
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatalf("write fake .env: %v", err)
		}
	}
	env, err := config.Load(path)
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	return env
}

func TestGetConfiguredPackerBases_ExtractsBases(t *testing.T) {
	env := loadTestEnv(t, `ALL_PACKER_BASES="base-a base-b"`+"\n")
	got := getConfiguredPackerBases(env)
	want := []string{"base-a", "base-b"}
	if len(got) != len(want) {
		t.Fatalf("getConfiguredPackerBases = %#v, want %#v", got, want)
	}
	for i := range got {
		if got[i] != want[i] {
			t.Fatalf("getConfiguredPackerBases = %#v, want %#v", got, want)
		}
	}
}

func TestGetConfiguredPackerBases_ReturnsEmptyWhenKeyAbsent(t *testing.T) {
	env := loadTestEnv(t, `ALL_TERRAFORM_LAYERS="layer-x"`+"\n")
	got := getConfiguredPackerBases(env)
	if len(got) != 0 {
		t.Fatalf("getConfiguredPackerBases with absent key = %#v, want empty", got)
	}
}

func TestGetConfiguredTerraformLayers_ExtractsLayers(t *testing.T) {
	env := loadTestEnv(t, `ALL_TERRAFORM_LAYERS="layer-x"`+"\n")
	got := getConfiguredTerraformLayers(env)
	want := []string{"layer-x"}
	if len(got) != len(want) {
		t.Fatalf("getConfiguredTerraformLayers = %#v, want %#v", got, want)
	}
	for i := range got {
		if got[i] != want[i] {
			t.Fatalf("getConfiguredTerraformLayers = %#v, want %#v", got, want)
		}
	}
}

func TestGetConfiguredTerraformLayers_ReturnsEmptyWhenKeyAbsent(t *testing.T) {
	env := loadTestEnv(t, `ALL_PACKER_BASES="base-a"`+"\n")
	got := getConfiguredTerraformLayers(env)
	if len(got) != 0 {
		t.Fatalf("getConfiguredTerraformLayers with absent key = %#v, want empty", got)
	}
}

func TestResolveProjectRoot_LocatesGitRoot(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	nested := filepath.Join(root, "tools", "platform")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		name  string
		start string
	}{
		{"at root", root},
		{"nested subdirectory", nested},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := resolveProjectRoot(c.start)
			if err != nil {
				t.Fatalf("resolveProjectRoot(%q): %v", c.start, err)
			}
			if got != root {
				t.Errorf("resolveProjectRoot(%q) = %q, want %q", c.start, got, root)
			}
		})
	}
}

func TestResolveProjectRoot_FailsWithoutGitDirectory(t *testing.T) {
	start := t.TempDir()

	if _, err := resolveProjectRoot(start); err == nil {
		t.Fatal("resolveProjectRoot: want error, got nil")
	}
}

func TestResolveBastionVaultAddr_PrioritizesInjectedAddress(t *testing.T) {
	env := loadTestEnv(t, `BASTION_VAULT_ADDR="https://from-env:8200"`+"\n")
	a := &app{bastionVaultAddr: "https://from-injection:8200", env: env}

	if got := a.resolveBastionVaultAddr(); got != "https://from-injection:8200" {
		t.Errorf("resolveBastionVaultAddr() = %q, want https://from-injection:8200", got)
	}
}

func TestResolveBastionVaultAddr_FallsBackToEnvironmentVariable(t *testing.T) {
	env := loadTestEnv(t, `BASTION_VAULT_ADDR="https://staging-bastion:8200"`+"\n")
	a := &app{env: env}

	if got := a.resolveBastionVaultAddr(); got != "https://staging-bastion:8200" {
		t.Errorf("resolveBastionVaultAddr() = %q, want https://staging-bastion:8200", got)
	}
}

func TestResolveBastionVaultAddr_FallsBackToUpstreamDefaultWhenUnset(t *testing.T) {
	a := &app{}

	if got := a.resolveBastionVaultAddr(); got != config.DefaultBastionVaultAddr {
		t.Errorf("resolveBastionVaultAddr() = %q, want %q", got, config.DefaultBastionVaultAddr)
	}
}

func TestPrintVaultStatusBanner_SucceedsWithNilEnv(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/sys/seal-status", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]interface{}{"initialized": true, "sealed": false})
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	root := t.TempDir()
	a := &app{root: root, home: t.TempDir(), bastionVaultAddr: srv.URL, out: ui.New(io.Discard, io.Discard)}

	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("printVaultStatusBanner panicked with a nil a.env: %v", r)
		}
	}()
	a.printVaultStatusBanner(context.Background())
}

func TestNewVaultPaths_InitializesFromAppFields(t *testing.T) {
	a := &app{root: "/r", home: "/h", terraform: "/tf", ansibleDir: "/ans"}
	got := a.newVaultPaths()

	if got.ProjectRoot != "/r" {
		t.Errorf("ProjectRoot = %q, want %q", got.ProjectRoot, "/r")
	}
	if got.AnsibleDir != "/ans" {
		t.Errorf("AnsibleDir = %q, want %q", got.AnsibleDir, "/ans")
	}
	if got.TerraformDir != "/tf" {
		t.Errorf("TerraformDir = %q, want %q", got.TerraformDir, "/tf")
	}
	if got.Home != "/h" {
		t.Errorf("Home = %q, want %q", got.Home, "/h")
	}
}

// TestRunMenu_Quit drives runMenu with "Quit" selected (option 10, the last entry) via an
// in-memory reader, matching the one selection whose dispatch (chosen.run == nil) requires
// no real infrastructure.
func TestRunMenu_ExitsOnQuitOption(t *testing.T) {
	var buf bytes.Buffer
	dir := t.TempDir()
	env, err := config.Load(filepath.Join(dir, ".env"))
	if err != nil {
		t.Fatalf("config.Load: %v", err)
	}
	a := &app{
		root:      dir,
		home:      dir,
		terraform: filepath.Join(dir, "terraform"),
		env:       env,
		out:       ui.New(&buf, &buf),
		in:        bufio.NewReader(strings.NewReader("10\n")),
	}

	if err := a.runMenu(context.Background()); err != nil {
		t.Fatalf("runMenu quit path returned error: %v", err)
	}

	if !strings.Contains(buf.String(), "Exiting.") {
		t.Errorf("output missing exit message, got: %s", buf.String())
	}
}
