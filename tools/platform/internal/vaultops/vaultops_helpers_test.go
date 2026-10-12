package vaultops

import (
	"encoding/json"
	"io"
	"net/http"
	"testing"

	vaultapi "github.com/hashicorp/vault/api"

	"platform/internal/ui"
)

// fakeEnv is a minimal test-local implementation of the one-method Set(string,string)
// interface TokenSync accepts. Tests assert on what was recorded.
type fakeEnv struct{ kv map[string]string }

func newFakeEnv() *fakeEnv { return &fakeEnv{kv: map[string]string{}} }

func (e *fakeEnv) Set(k, v string) { e.kv[k] = v }

func discardOut() *ui.Printer { return ui.New(io.Discard, io.Discard) }

// kvv2Handler serves a fake Vault KV-v2 "read" response for exactly one mount/path pair.
func kvv2Handler(t *testing.T, wantPath string, body map[string]interface{}) http.HandlerFunc {
	t.Helper()
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != wantPath {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"errors":["not found"]}`))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(body)
	}
}

func newTestVaultClient(t *testing.T, addr string) *vaultapi.Client {
	t.Helper()
	cfg := vaultapi.DefaultConfig()
	cfg.Address = addr
	client, err := vaultapi.NewClient(cfg)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	return client
}
