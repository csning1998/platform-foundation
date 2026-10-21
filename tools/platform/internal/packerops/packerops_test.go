package packerops

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	vaultapi "github.com/hashicorp/vault/api"

	"platform/internal/ui"
)

// newGuestCredentialClient returns a Vault client of a fake KV v2 leaf at secret/<guestCredentialPath> holding data.
func newGuestCredentialClient(t *testing.T, data map[string]any) *vaultapi.Client {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/secret/data/"+guestCredentialPath {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"data": data, "metadata": map[string]any{}}})
	}))
	t.Cleanup(srv.Close)
	cfg := vaultapi.DefaultConfig()
	cfg.Address = srv.URL
	client, err := vaultapi.NewClient(cfg)
	if err != nil {
		t.Fatalf("vaultapi.NewClient: %v", err)
	}
	client.SetToken("test-token")
	return client
}

func TestReadGuestCredentialEnv_ReturnsOneEntryPerField(t *testing.T) {
	client := newGuestCredentialClient(t, map[string]any{
		"ssh_username": "user", "ssh_password": "pass", "ssh_password_hash": "hash", "ssh_public_key_path": "/key.pub",
	})

	got, err := ReadGuestCredentialEnv(context.Background(), client)
	if err != nil {
		t.Fatalf("ReadGuestCredentialEnv: %v", err)
	}
	want := []string{
		"PKR_VAR_ssh_username=user", "PKR_VAR_ssh_password=pass",
		"PKR_VAR_ssh_password_hash=hash", "PKR_VAR_ssh_public_key_path=/key.pub",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("ReadGuestCredentialEnv = %q, want %q", got, want)
	}
}

func TestReadGuestCredentialEnv_NamesTheMissingFieldWithoutValues(t *testing.T) {
	client := newGuestCredentialClient(t, map[string]any{"ssh_username": "user", "ssh_password": "secret-value"})

	_, err := ReadGuestCredentialEnv(context.Background(), client)
	if !errors.Is(err, ErrGuestCredentialMissing) || !strings.Contains(err.Error(), "ssh_password_hash") {
		t.Fatalf("ReadGuestCredentialEnv error = %v, want ErrGuestCredentialMissing naming ssh_password_hash", err)
	}
	if strings.Contains(err.Error(), "secret-value") {
		t.Errorf("ReadGuestCredentialEnv error %q contains a credential value", err)
	}
}

func TestResolveBaseCategoryDir_PrefersDistro(t *testing.T) {
	dir := t.TempDir()
	mustMkdirAll(t, filepath.Join(dir, "distro"))
	mustMkdirAll(t, filepath.Join(dir, "services"))
	mustWriteFile(t, filepath.Join(dir, "distro", "ubuntu-24.pkrvars.hcl"), "")

	if got := resolveBaseCategoryDir(dir, "ubuntu-24"); got != "distro" {
		t.Errorf("resolveBaseCategoryDir() = %q, want distro", got)
	}
	if got := resolveBaseCategoryDir(dir, "not-a-distro-base"); got != "services" {
		t.Errorf("resolveBaseCategoryDir() for unknown base = %q, want services", got)
	}
}

func TestBaseExists_VerifiesExistenceAcrossCategories(t *testing.T) {
	dir := t.TempDir()
	mustMkdirAll(t, filepath.Join(dir, "distro"))
	mustMkdirAll(t, filepath.Join(dir, "services"))
	mustWriteFile(t, filepath.Join(dir, "distro", "ubuntu-24.pkrvars.hcl"), "")
	mustWriteFile(t, filepath.Join(dir, "services", "base-docker-harbor.pkrvars.hcl"), "")

	cases := map[string]bool{
		"ubuntu-24":          true,
		"base-docker-harbor": true,
		"ubuntu-25":          false,
		"":                   false,
		"Ubuntu-24":          false, // case-sensitive
		"ubuntu-24 ":         false, // no trimming
	}
	for base, want := range cases {
		if got := BaseExists(dir, base); got != want {
			t.Errorf("BaseExists(%q) = %v, want %v", base, got, want)
		}
	}
}

func TestBaseExists_ReturnsTrueWhenBothCategoriesPresent(t *testing.T) {
	dir := t.TempDir()
	mustMkdirAll(t, filepath.Join(dir, "distro"))
	mustMkdirAll(t, filepath.Join(dir, "services"))
	mustWriteFile(t, filepath.Join(dir, "distro", "shared-base.pkrvars.hcl"), "")
	mustWriteFile(t, filepath.Join(dir, "services", "shared-base.pkrvars.hcl"), "")

	if !BaseExists(dir, "shared-base") {
		t.Error("BaseExists(shared-base) = false, want true when present in both categories")
	}
}

func TestBaseExists_ReturnsFalseOnNonexistentPackerDir(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "does-not-exist")
	if BaseExists(dir, "anything") {
		t.Error("BaseExists on a nonexistent packerDir = true, want false")
	}
}

func TestListBases_SortsAndFiltersSuffix(t *testing.T) {
	dir := t.TempDir()
	sub := filepath.Join(dir, "distro")
	mustMkdirAll(t, sub)
	mustWriteFile(t, filepath.Join(sub, "ubuntu-24.pkrvars.hcl"), "")
	mustWriteFile(t, filepath.Join(sub, "fedora-44.pkrvars.hcl"), "")
	mustWriteFile(t, filepath.Join(sub, "README.md"), "")

	got, err := listBases(dir, "distro")
	if err != nil {
		t.Fatalf("listBases: %v", err)
	}
	want := []string{"fedora-44", "ubuntu-24"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Errorf("listBases = %v, want %v", got, want)
	}
}

func TestClean_RemovesOnlyRequestedBaseOutput(t *testing.T) {
	dir := t.TempDir()
	mustMkdirAll(t, filepath.Join(dir, "output", "base-a"))
	mustMkdirAll(t, filepath.Join(dir, "output", "base-b"))

	out := ui.New(discard{}, discard{})
	if err := Clean(dir, "base-a", nil, t.TempDir(), out); err != nil {
		t.Fatalf("Clean: %v", err)
	}

	if _, err := os.Stat(filepath.Join(dir, "output", "base-a")); !os.IsNotExist(err) {
		t.Error("base-a output should have been removed")
	}
	if _, err := os.Stat(filepath.Join(dir, "output", "base-b")); err != nil {
		t.Error("base-b output should have survived Clean(\"base-a\")")
	}
}

func TestClean_IsIdempotentOnAlreadyMissingOutput(t *testing.T) {
	dir := t.TempDir()
	out := ui.New(discard{}, discard{})
	if err := Clean(dir, "never-built", nil, t.TempDir(), out); err != nil {
		t.Errorf("Clean on a base with no output dir yet = %v, want nil (idempotent)", err)
	}
}

func TestCleanAll_TouchesNothingWithNoDiscoveredBases(t *testing.T) {
	dir := t.TempDir()
	mustMkdirAll(t, filepath.Join(dir, "output", "some-other-base"))

	out := ui.New(discard{}, discard{})
	if err := Clean(dir, "all", nil, t.TempDir(), out); err != nil {
		t.Fatalf("Clean(all, nil): %v", err)
	}

	if _, err := os.Stat(filepath.Join(dir, "output", "some-other-base")); err != nil {
		t.Error("output dir should have survived Clean(all) with no discovered bases")
	}
}

func TestCleanAll_RemovesEveryListedBase(t *testing.T) {
	dir := t.TempDir()
	mustMkdirAll(t, filepath.Join(dir, "output", "base-a"))
	mustMkdirAll(t, filepath.Join(dir, "output", "base-b"))
	mustMkdirAll(t, filepath.Join(dir, "output", "base-c"))

	out := ui.New(discard{}, discard{})
	if err := Clean(dir, "all", []string{"base-a", "base-b"}, t.TempDir(), out); err != nil {
		t.Fatalf("Clean(all, [base-a, base-b]): %v", err)
	}

	if _, err := os.Stat(filepath.Join(dir, "output", "base-a")); !os.IsNotExist(err) {
		t.Error("base-a output should have been removed")
	}
	if _, err := os.Stat(filepath.Join(dir, "output", "base-b")); !os.IsNotExist(err) {
		t.Error("base-b output should have been removed")
	}
	if _, err := os.Stat(filepath.Join(dir, "output", "base-c")); err != nil {
		t.Error("base-c output should have survived Clean(all) since it wasn't in allBases")
	}
}

func TestCleanCacheSweep_PreservesISORemovesOtherEntries(t *testing.T) {
	dir := t.TempDir()
	cacheDir := t.TempDir()
	mustWriteFile(t, filepath.Join(cacheDir, "keep.iso"), "iso-content")
	mustWriteFile(t, filepath.Join(cacheDir, "junk.txt"), "junk")
	mustMkdirAll(t, filepath.Join(cacheDir, "stale-build"))

	out := ui.New(discard{}, discard{})
	if err := Clean(dir, "never-built", nil, cacheDir, out); err != nil {
		t.Fatalf("Clean with cache sweep: %v", err)
	}

	if _, err := os.Stat(filepath.Join(cacheDir, "keep.iso")); err != nil {
		t.Error(".iso entry must never be targeted by the cache sweep")
	}
	// Cache cleanup SHALL execute unprivileged removal via os.RemoveAll for user-owned entries without invoking sudo.
	if _, err := os.Stat(filepath.Join(cacheDir, "junk.txt")); !os.IsNotExist(err) {
		t.Errorf("junk.txt still present after sweep, stat err = %v", err)
	}
	if _, err := os.Stat(filepath.Join(cacheDir, "stale-build")); !os.IsNotExist(err) {
		t.Errorf("stale-build still present after sweep, stat err = %v", err)
	}
}

func TestCleanCacheSweep_FallsBackToSudoWhenRemoveAllFails(t *testing.T) {
	dir := t.TempDir()
	cacheDir := t.TempDir()
	unremovableDir := filepath.Join(cacheDir, "locked")
	mustMkdirAll(t, unremovableDir)
	mustWriteFile(t, filepath.Join(unremovableDir, "inside"), "x")
	if err := os.Chmod(cacheDir, 0o500); err != nil {
		t.Fatalf("chmod cacheDir read-only: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(cacheDir, 0o700) })

	out := ui.New(discard{}, discard{})
	// Verifies that cache cleanup failures caused by read-only parent directory permissions emit a warning log
	// and return a nil error without propagating non-fatal errors.
	if err := Clean(dir, "never-built", nil, cacheDir, out); err != nil {
		t.Fatalf("Clean with unremovable cache entry: %v", err)
	}
}

func TestClean_SucceedsWithNonexistentCacheDir(t *testing.T) {
	dir := t.TempDir()
	missingCacheDir := filepath.Join(t.TempDir(), "does-not-exist")

	out := ui.New(discard{}, discard{})
	if err := Clean(dir, "never-built", nil, missingCacheDir, out); err != nil {
		t.Errorf("Clean with nonexistent cacheDir = %v, want nil (sweep silently skipped)", err)
	}
}

func TestBuild_ReturnsErrorWhenVarFileMissing(t *testing.T) {
	dir := t.TempDir()
	mustMkdirAll(t, filepath.Join(dir, "distro"))
	mustMkdirAll(t, filepath.Join(dir, "services"))

	out := ui.New(discard{}, discard{})
	err := Build(t.Context(), dir, "no-such-base", nil, out)
	if err == nil {
		t.Fatal("Build with missing var file: want error, got nil")
	}
	wantPath := filepath.Join(dir, "services", "no-such-base.pkrvars.hcl")
	if !strings.Contains(err.Error(), "var file not found") || !strings.Contains(err.Error(), wantPath) {
		t.Errorf("Build error = %q, want it to contain %q and %q", err.Error(), "var file not found", wantPath)
	}
}

func TestResolveBaseCategoryDir_PrefersDistroWhenBothCategoriesPresent(t *testing.T) {
	dir := t.TempDir()
	mustMkdirAll(t, filepath.Join(dir, "distro"))
	mustMkdirAll(t, filepath.Join(dir, "services"))
	mustWriteFile(t, filepath.Join(dir, "distro", "shared-base.pkrvars.hcl"), "")
	mustWriteFile(t, filepath.Join(dir, "services", "shared-base.pkrvars.hcl"), "")

	if got := resolveBaseCategoryDir(dir, "shared-base"); got != "distro" {
		t.Errorf("resolveBaseCategoryDir() with base in both = %q, want distro", got)
	}
}

func TestResolveBaseCategoryDir_DefaultsToServicesOnNonexistentPackerDir(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "does-not-exist")

	if got := resolveBaseCategoryDir(dir, "any-base"); got != "services" {
		t.Errorf("resolveBaseCategoryDir() with nonexistent packerDir = %q, want services", got)
	}
}

func TestListBases_ListsDistroAndServiceBases(t *testing.T) {
	dir := t.TempDir()
	mustMkdirAll(t, filepath.Join(dir, "distro"))
	mustMkdirAll(t, filepath.Join(dir, "services"))
	mustWriteFile(t, filepath.Join(dir, "distro", "ubuntu-24.pkrvars.hcl"), "")
	mustWriteFile(t, filepath.Join(dir, "services", "nginx.pkrvars.hcl"), "")

	distro, err := ListDistroBases(dir)
	if err != nil {
		t.Fatalf("ListDistroBases: %v", err)
	}
	if len(distro) != 1 || distro[0] != "ubuntu-24" {
		t.Errorf("ListDistroBases() = %v, want [ubuntu-24]", distro)
	}

	services, err := ListServiceBases(dir)
	if err != nil {
		t.Fatalf("ListServiceBases: %v", err)
	}
	if len(services) != 1 || services[0] != "nginx" {
		t.Errorf("ListServiceBases() = %v, want [nginx]", services)
	}
}

func TestGenerateQcow2Checksum_ReturnsNilWhenOutputDirMissing(t *testing.T) {
	missingDir := filepath.Join(t.TempDir(), "does-not-exist")
	out := ui.New(discard{}, discard{})
	if err := generateQcow2Checksum(missingDir, out); err != nil {
		t.Errorf("generateQcow2Checksum on missing outputDir = %v, want nil", err)
	}
}

func TestGenerateQcow2Checksum_WritesNothingWhenOutputDirEmpty(t *testing.T) {
	dir := t.TempDir()
	out := ui.New(discard{}, discard{})
	if err := generateQcow2Checksum(dir, out); err != nil {
		t.Errorf("generateQcow2Checksum on empty outputDir = %v, want nil", err)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	if len(entries) != 0 {
		t.Errorf("generateQcow2Checksum on empty outputDir must not create files, got %v", entries)
	}
}

func TestGenerateQcow2Checksum_WritesExactSha256Line(t *testing.T) {
	dir := t.TempDir()
	content := "fake-qcow2-image-bytes"
	mustWriteFile(t, filepath.Join(dir, "image.qcow2"), content)

	out := ui.New(discard{}, discard{})
	if err := generateQcow2Checksum(dir, out); err != nil {
		t.Fatalf("generateQcow2Checksum: %v", err)
	}

	sum := sha256.Sum256([]byte(content))
	want := hex.EncodeToString(sum[:]) + "  image.qcow2\n"

	got, err := os.ReadFile(filepath.Join(dir, "image.qcow2.sha256"))
	if err != nil {
		t.Fatalf("read .sha256: %v", err)
	}
	if string(got) != want {
		t.Errorf("checksum file content = %q, want %q", string(got), want)
	}
}

func TestGenerateQcow2Checksum_OnlyChecksumsQcow2AmongOtherFileTypes(t *testing.T) {
	dir := t.TempDir()
	mustWriteFile(t, filepath.Join(dir, "notes.txt"), "not an image")
	mustWriteFile(t, filepath.Join(dir, "build.log"), "log output")
	mustWriteFile(t, filepath.Join(dir, "image.qcow2"), "the actual image")

	out := ui.New(discard{}, discard{})
	if err := generateQcow2Checksum(dir, out); err != nil {
		t.Fatalf("generateQcow2Checksum: %v", err)
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	sumCount := 0
	for _, e := range entries {
		if filepath.Ext(e.Name()) == ".sha256" {
			sumCount++
		}
	}
	if sumCount != 1 {
		t.Errorf("expected exactly one .sha256 file, got %d among %v", sumCount, entries)
	}
	if _, err := os.Stat(filepath.Join(dir, "image.qcow2.sha256")); err != nil {
		t.Error("image.qcow2.sha256 should exist")
	}
}

func TestGenerateQcow2Checksum_ChecksumsAlphabeticallyFirstWhenMultipleQcow2(t *testing.T) {
	dir := t.TempDir()
	mustWriteFile(t, filepath.Join(dir, "a-image.qcow2"), "content-a")
	mustWriteFile(t, filepath.Join(dir, "z-image.qcow2"), "content-z")

	out := ui.New(discard{}, discard{})
	if err := generateQcow2Checksum(dir, out); err != nil {
		t.Fatalf("generateQcow2Checksum with two .qcow2 files: %v", err)
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	sumCount := 0
	for _, e := range entries {
		if filepath.Ext(e.Name()) == ".sha256" {
			sumCount++
		}
	}
	if sumCount != 1 {
		t.Errorf("expected exactly one .sha256 file when two .qcow2 images present, got %d among %v", sumCount, entries)
	}
	if _, err := os.Stat(filepath.Join(dir, "a-image.qcow2.sha256")); err != nil {
		t.Error("expected a-image.qcow2.sha256 (alphabetically first entry from os.ReadDir) to be the one checksummed")
	}
	if _, err := os.Stat(filepath.Join(dir, "z-image.qcow2.sha256")); err == nil {
		t.Error("z-image.qcow2.sha256 should not exist; only the first match should be checksummed")
	}
}

type discard struct{}

func (discard) Write(p []byte) (int, error) { return len(p), nil }

func mustMkdirAll(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", path, err)
	}
}

func mustWriteFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}
