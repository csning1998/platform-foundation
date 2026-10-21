package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestLoad_YieldsEmptyEnvOnMissingFile(t *testing.T) {
	e, err := Load(filepath.Join(t.TempDir(), "does-not-exist.env"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := e.Get("ANYTHING"); got != "" {
		t.Errorf("Get on empty Env = %q, want empty", got)
	}
}

func TestLoad_RoundTripsWithSave(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	content := "PROJECT_ROOT=\"/repo\"\nUNAME=csning1998\nUHOME=${HOME}\n# comment line\n\nSONAR_DB_PASSWORD=\"secret with spaces\"\n"
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	e, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	cases := map[string]string{
		"PROJECT_ROOT":      "/repo",
		"UNAME":             "csning1998",
		"UHOME":             "${HOME}",
		"SONAR_DB_PASSWORD": "secret with spaces",
	}
	for key, want := range cases {
		if got := e.Get(key); got != want {
			t.Errorf("Get(%q) = %q, want %q", key, got, want)
		}
	}

	// A key absent from the loader's known set (SONAR_DB_PASSWORD) must survive a save
	// unchanged, matching Bootstrap's non-destructive handling of unrelated keys.
	e.Set(KeyProjectRoot, "/repo2")
	if err := e.Save(); err != nil {
		t.Fatalf("Save: %v", err)
	}

	reloaded, err := Load(path)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	if got := reloaded.Get("SONAR_DB_PASSWORD"); got != "secret with spaces" {
		t.Errorf("SONAR_DB_PASSWORD after save = %q, want unchanged", got)
	}
	if got := reloaded.Get(KeyProjectRoot); got != "/repo2" {
		t.Errorf("PROJECT_ROOT after save = %q, want /repo2", got)
	}
}

func TestEnviron_ExpandsReferences(t *testing.T) {
	t.Setenv("HOME", "/home/tester")

	e := &Env{values: map[string]string{}}
	e.Set("PROJECT_ROOT", "/repo")
	e.Set("BASTION_VAULT_CACERT", "${PROJECT_ROOT}/vault/tls/ca.pem")
	e.Set("UHOME", "${HOME}")
	e.Set("PLAIN", "no-refs-here")

	got := map[string]string{}
	for _, kv := range e.Environ() {
		key, value, _ := splitKV(kv)
		got[key] = value
	}

	want := map[string]string{
		"PROJECT_ROOT":         "/repo",
		"BASTION_VAULT_CACERT": "/repo/vault/tls/ca.pem",
		"UHOME":                "/home/tester",
		"PLAIN":                "no-refs-here",
	}
	for key, wantVal := range want {
		if got[key] != wantVal {
			t.Errorf("Environ()[%q] = %q, want %q", key, got[key], wantVal)
		}
	}
}

func TestGetExpandedOrDefault_PrefersEnvAndExpandsFallback(t *testing.T) {
	e := &Env{values: map[string]string{}}
	e.Set("PROJECT_ROOT", "/repo")
	e.Set("DECLARED", "${PROJECT_ROOT}/declared.pem")

	cases := []struct {
		name string
		env  *Env
		key  string
		want string
	}{
		{"declared key wins", e, "DECLARED", "/repo/declared.pem"},
		{"absent key expands fallback", e, "ABSENT", "/repo/fallback.pem"},
		{"nil env returns fallback verbatim", nil, "ABSENT", "${PROJECT_ROOT}/fallback.pem"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := c.env.GetExpandedOrDefault(c.key, "${PROJECT_ROOT}/fallback.pem"); got != c.want {
				t.Errorf("GetExpandedOrDefault(%q) = %q, want %q", c.key, got, c.want)
			}
		})
	}
}

func splitKV(kv string) (key, value string, ok bool) {
	for i := 0; i < len(kv); i++ {
		if kv[i] == '=' {
			return kv[:i], kv[i+1:], true
		}
	}
	return kv, "", false
}

func TestLoad_HandlesLineParsingEdgeCases(t *testing.T) {
	cases := []struct {
		name    string
		content string
		key     string
		want    string
		absent  bool
	}{
		{"no equals sign ignored", "NOEQUALS\n", "NOEQUALS", "", true},
		{"leading whitespace before key not matched", "  KEY=value\n", "KEY", "", true},
		{"empty quoted value", `KEY=""` + "\n", "KEY", "", false},
		{"value containing equals", "KEY=a=b=c\n", "KEY", "a=b=c", false},
		{"malformed line starting with digit", "1KEY=value\n", "1KEY", "", true},
		{"crlf line ending", "KEY=value\r\n", "KEY", "value", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), ".env")
			mustWriteFile(t, path, tc.content)

			e, err := Load(path)
			if err != nil {
				t.Fatalf("Load: %v", err)
			}
			got := e.Get(tc.key)
			if tc.absent {
				if _, ok := e.values[tc.key]; ok {
					t.Errorf("key %q present in values, want absent (line ignored)", tc.key)
				}
				return
			}
			if got != tc.want {
				t.Errorf("Get(%q) = %q, want %q", tc.key, got, tc.want)
			}
		})
	}
}

func TestLoad_PreservesTrailingWhitespaceInUnquotedValue(t *testing.T) {
	// envLineRe's [^"]* group is greedy. That group consumes the trailing whitespace
	// before the optional closing quote and \s* anchor get a chance to strip that
	// whitespace. An unquoted value keeps trailing spaces verbatim.
	path := filepath.Join(t.TempDir(), ".env")
	mustWriteFile(t, path, "KEY=value   \n")

	e, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := e.Get("KEY"); got != "value   " {
		t.Errorf("Get(KEY) = %q, want %q (trailing whitespace retained)", got, "value   ")
	}
}

func TestLoad_StripsTrailingWhitespaceOutsideQuotes(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	mustWriteFile(t, path, `KEY="value"   `+"\n")

	e, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := e.Get("KEY"); got != "value" {
		t.Errorf("Get(KEY) = %q, want %q", got, "value")
	}
}

func TestLoad_ReturnsErrorOnDirectory(t *testing.T) {
	dir := t.TempDir()
	if _, err := Load(dir); err == nil {
		t.Error("Load on a directory path = nil error, want error")
	}
}

func TestLoad_LastWinsOnDuplicateKeyWithoutDuplicateOrder(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	mustWriteFile(t, path, "KEY=first\nKEY=second\n")

	e, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := e.Get("KEY"); got != "second" {
		t.Errorf("Get(KEY) = %q, want %q", got, "second")
	}
	if err := e.Save(); err != nil {
		t.Fatalf("Save: %v", err)
	}
	saved, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read saved file: %v", err)
	}
	lines := strings.Split(strings.TrimRight(string(saved), "\n"), "\n")
	if len(lines) != 1 {
		t.Errorf("Save() wrote %d lines for a duplicate key, want 1: %q", len(lines), string(saved))
	}
}

func TestEnvSet_PreservesOrderOnOverwrite(t *testing.T) {
	e := &Env{values: map[string]string{}}
	e.Set("FIRST", "1")
	e.Set("SECOND", "2")
	e.Set("FIRST", "1-updated")

	path := filepath.Join(t.TempDir(), ".env")
	e.path = path
	if err := e.Save(); err != nil {
		t.Fatalf("Save: %v", err)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read saved file: %v", err)
	}
	want := "FIRST=\"1-updated\"\nSECOND=\"2\"\n"
	if string(content) != want {
		t.Errorf("Save() content = %q, want %q", string(content), want)
	}
}

func TestEnvGet_ReturnsEmptyOnZeroValueEnv(t *testing.T) {
	e := &Env{}
	if got := e.Get("ANYTHING"); got != "" {
		t.Errorf("Get on zero-value Env = %q, want empty", got)
	}
}

func TestEnvSave_WritesEmptyFileForEmptyEnv(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	e := &Env{path: path, values: map[string]string{}}
	if err := e.Save(); err != nil {
		t.Fatalf("Save: %v", err)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read saved file: %v", err)
	}
	if len(content) != 0 {
		t.Errorf("Save() on empty Env wrote %q, want empty file", string(content))
	}
}

func TestEnvSave_RoundTripsQuoting(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	e := &Env{path: path, values: map[string]string{}}
	e.Set("KEY", `has "quotes" inside`)
	if err := e.Save(); err != nil {
		t.Fatalf("Save: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read saved file: %v", err)
	}
	wantRaw := `KEY="has \"quotes\" inside"` + "\n"
	if string(raw) != wantRaw {
		t.Fatalf("saved raw content = %q, want %q", string(raw), wantRaw)
	}

	reloaded, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := reloaded.Get("KEY"); got != `has "quotes" inside` {
		t.Errorf("reloaded KEY = %q, want %q", got, `has "quotes" inside`)
	}
}

func TestEnviron_SelfReferenceDoesNotHangOrPanic(t *testing.T) {
	t.Run("unset in process env", func(t *testing.T) {
		e := &Env{values: map[string]string{}}
		e.Set("A", "${A}")

		done := make(chan []string, 1)
		go func() { done <- e.Environ() }()
		select {
		case got := <-done:
			key, value, _ := splitKV(got[0])
			if key != "A" || value != "" {
				t.Errorf("Environ() self-ref = %q=%q, want A=\"\"", key, value)
			}
		case <-timeoutChan(t):
			t.Fatal("Environ() on self-referential key hung")
		}
	})

	t.Run("set in process env", func(t *testing.T) {
		t.Setenv("A", "from-process-env")
		e := &Env{values: map[string]string{}}
		e.Set("A", "${A}")

		got := e.Environ()
		key, value, _ := splitKV(got[0])
		if key != "A" || value != "from-process-env" {
			t.Errorf("Environ() self-ref = %q=%q, want A=%q", key, value, "from-process-env")
		}
	})
}

func TestEnviron_HandlesMultipleAndUnresolvedRefs(t *testing.T) {
	t.Setenv("EXTERNAL_SET", "ext-value")
	_ = os.Unsetenv("EXTERNAL_UNSET")

	e := &Env{values: map[string]string{}}
	e.Set("A", "alpha")
	e.Set("B", "beta")
	e.Set("COMBO", "${A}-${B}")
	e.Set("FORWARD_REF", "${LATER}")
	e.Set("LATER", "later-value")
	e.Set("FROM_PROCESS_SET", "${EXTERNAL_SET}")
	e.Set("FROM_PROCESS_UNSET", "${EXTERNAL_UNSET}")
	e.Set("ADJACENT", "${A}${B}")

	got := map[string]string{}
	for _, kv := range e.Environ() {
		key, value, _ := splitKV(kv)
		got[key] = value
	}

	want := map[string]string{
		"COMBO":              "alpha-beta",
		"FORWARD_REF":        "", // LATER is defined after FORWARD_REF, falls to os.Getenv
		"FROM_PROCESS_SET":   "ext-value",
		"FROM_PROCESS_UNSET": "",
		"ADJACENT":           "alphabeta",
	}
	for key, wantVal := range want {
		if got[key] != wantVal {
			t.Errorf("Environ()[%q] = %q, want %q", key, got[key], wantVal)
		}
	}
}

func TestGetExpanded_ExpandsVariables(t *testing.T) {
	t.Setenv("EXTERNAL_KEY", "ext-val")
	e := &Env{values: map[string]string{}}
	e.Set("ROOT", "/repo")
	e.Set("CERT", "${ROOT}/tls/ca.pem")
	e.Set("FROM_EXT", "${EXTERNAL_KEY}")

	if got := e.GetExpanded("CERT"); got != "/repo/tls/ca.pem" {
		t.Errorf("GetExpanded(CERT) = %q, want %q", got, "/repo/tls/ca.pem")
	}
	if got := e.GetExpanded("FROM_EXT"); got != "ext-val" {
		t.Errorf("GetExpanded(FROM_EXT) = %q, want %q", got, "ext-val")
	}
	if got := e.GetExpanded("MISSING"); got != "" {
		t.Errorf("GetExpanded(MISSING) = %q, want empty", got)
	}

	var nilEnv *Env
	if got := nilEnv.GetExpanded("CERT"); got != "" {
		t.Errorf("nilEnv.GetExpanded = %q, want empty", got)
	}
	if got := nilEnv.Expand("hello ${ROOT}"); got != "hello ${ROOT}" {
		t.Errorf("nilEnv.Expand = %q, want unmodified", got)
	}
}

func timeoutChan(t *testing.T) <-chan struct{} {
	t.Helper()
	ch := make(chan struct{})
	go func() {
		<-time.After(5 * time.Second)
		close(ch)
	}()
	return ch
}

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
