package terraformops

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeLayer writes providers.tf of layer under dir/layers with the given content.
func writeLayer(t *testing.T, dir, layer, content string) {
	t.Helper()
	layerDir := filepath.Join(dir, "layers", layer)
	if err := os.MkdirAll(layerDir, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", layer, err)
	}
	if err := os.WriteFile(filepath.Join(layerDir, "providers.tf"), []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", layer, err)
	}
}

func backendBlock(state string) string {
	return "terraform {\n  backend \"http\" {\n    address        = \"https://gitlab.example/api/v4/projects/7/terraform/state/" + state +
		"\"\n    lock_address   = \"https://gitlab.example/api/v4/projects/7/terraform/state/" + state + "/lock\"\n  }\n}\n"
}

func TestListPurgeableStates_ReadsTheBackendAndRetainsAdministrationLayers(t *testing.T) {
	dir := t.TempDir()
	writeLayer(t, dir, "platform-b", backendBlock("platform-b-frontend")+"provider \"vault\" {\n  address = local.vault_endpoint\n}\n")
	writeLayer(t, dir, "foundation-a", backendBlock("foundation-a"))
	writeLayer(t, dir, "administration-gitlab-project", backendBlock("administration-gitlab-project"))
	writeLayer(t, dir, "helper-without-backend", "locals {}\n")

	got, err := ListPurgeableStates(dir)
	if err != nil {
		t.Fatalf("ListPurgeableStates: %v", err)
	}
	want := []RemoteState{
		{Layer: "foundation-a", Address: "https://gitlab.example/api/v4/projects/7/terraform/state/foundation-a"},
		{Layer: "platform-b", Address: "https://gitlab.example/api/v4/projects/7/terraform/state/platform-b-frontend"},
	}
	if len(got) != len(want) {
		t.Fatalf("ListPurgeableStates = %+v, want %+v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("ListPurgeableStates[%d] = %+v, want %+v", i, got[i], want[i])
		}
	}
}

func TestDeleteRemoteState_SendsTheTokenAndAcceptsAnAbsentState(t *testing.T) {
	var gotMethod, gotToken string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotToken = r.Method, r.Header.Get("PRIVATE-TOKEN")
		if strings.HasSuffix(r.URL.Path, "/absent") {
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	for _, name := range []string{"present", "absent"} {
		state := RemoteState{Layer: name, Address: srv.URL + "/api/v4/projects/7/terraform/state/" + name}
		if err := DeleteRemoteState(context.Background(), srv.Client(), "test-token", state); err != nil {
			t.Errorf("DeleteRemoteState(%s): %v", name, err)
		}
		if gotMethod != http.MethodDelete || gotToken != "test-token" {
			t.Errorf("request of %s = %s with token %q, want DELETE with test-token", name, gotMethod, gotToken)
		}
	}
}

func TestDeleteRemoteState_ReportsTheStatusWithoutTheToken(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	defer srv.Close()

	err := DeleteRemoteState(context.Background(), srv.Client(), "secret-token", RemoteState{Layer: "layer-a", Address: srv.URL})
	if err == nil || !strings.Contains(err.Error(), "HTTP 403") {
		t.Fatalf("DeleteRemoteState error = %v, want HTTP 403", err)
	}
	if strings.Contains(err.Error(), "secret-token") {
		t.Errorf("DeleteRemoteState error %q contains the token", err)
	}
}
