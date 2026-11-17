package terraformops

import (
	"context"
	"errors"
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

const testStateBase = "https://gitlab.example/api/v4/projects/7/terraform/state"

// backendBlock omits the backend address, matching the shared HTTP backend block of every layer.
const backendBlock = "terraform {\n  backend \"http\" {\n    lock_method = \"POST\"\n  }\n}\n"

func TestListPurgeableStates_DerivesTheAddressAndRetainsAdministrationLayers(t *testing.T) {
	dir := t.TempDir()
	writeLayer(t, dir, "platform-b", backendBlock+"provider \"vault\" {\n  address = local.vault_endpoint\n}\n")
	writeLayer(t, dir, "foundation-a", backendBlock)
	writeLayer(t, dir, "administration-gitlab-project", backendBlock)
	writeLayer(t, dir, "helper-without-backend", "locals {}\n")

	got, err := ListPurgeableStates(dir, testStateBase)
	if err != nil {
		t.Fatalf("ListPurgeableStates: %v", err)
	}
	want := []RemoteState{
		{Layer: "foundation-a", Address: testStateBase + "/foundation-a"},
		{Layer: "platform-b", Address: testStateBase + "/platform-b"},
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

func TestListPurgeableStates_RequiresTheStateBase(t *testing.T) {
	dir := t.TempDir()
	writeLayer(t, dir, "foundation-a", backendBlock)
	if _, err := ListPurgeableStates(dir, ""); !errors.Is(err, ErrStateBaseMissing) {
		t.Errorf("ListPurgeableStates error = %v, want ErrStateBaseMissing", err)
	}
}

func TestBuildLayerBackendEnv_DerivesTheAddressesFromTheLayerDirectory(t *testing.T) {
	got, err := BuildLayerBackendEnv(testStateBase, "/repo/terraform/layers/platform-b")
	if err != nil {
		t.Fatalf("BuildLayerBackendEnv: %v", err)
	}
	want := []string{
		"TF_HTTP_ADDRESS=" + testStateBase + "/platform-b",
		"TF_HTTP_LOCK_ADDRESS=" + testStateBase + "/platform-b/lock",
		"TF_HTTP_UNLOCK_ADDRESS=" + testStateBase + "/platform-b/lock",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("BuildLayerBackendEnv = %q, want %q", got, want)
	}
}

func TestBuildLayerBackendEnv_RequiresTheStateBase(t *testing.T) {
	if _, err := BuildLayerBackendEnv("", "/repo/terraform/layers/platform-b"); !errors.Is(err, ErrStateBaseMissing) {
		t.Errorf("BuildLayerBackendEnv error = %v, want ErrStateBaseMissing", err)
	}
}

func TestListPurgeableStates_FailsWithoutTheLayersDirectory(t *testing.T) {
	if _, err := ListPurgeableStates(t.TempDir(), testStateBase); err == nil {
		t.Error("ListPurgeableStates() error = nil, want the failure to read a missing layers directory")
	}
}

func TestListPurgeableStates_FailsOnAnUnreadableTerraformFile(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "layers", "platform-a", "broken.tf"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if _, err := ListPurgeableStates(dir, testStateBase); err == nil {
		t.Error("ListPurgeableStates() error = nil, want the failure to read a .tf path which is a directory")
	}
}

func TestListPurgeableStates_FailsOnALayerNameWhichBreaksTheGlob(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "layers", "platform-["), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if _, err := ListPurgeableStates(dir, testStateBase); err == nil {
		t.Error("ListPurgeableStates() error = nil, want the glob failure of a layer name with an unclosed bracket")
	}
}

func TestDeleteRemoteState_FailsOnAnInvalidAddress(t *testing.T) {
	state := RemoteState{Layer: "layer-a", Address: "http://\x7f"}
	if err := DeleteRemoteState(context.Background(), http.DefaultClient, "token", state); err == nil {
		t.Error("DeleteRemoteState() error = nil, want the failure to build a request for an invalid address")
	}
}

func TestDeleteRemoteState_FailsWhenTheBackendIsUnreachable(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	address := srv.URL
	srv.Close()
	if err := DeleteRemoteState(context.Background(), http.DefaultClient, "token", RemoteState{Layer: "layer-a", Address: address}); err == nil {
		t.Error("DeleteRemoteState() error = nil, want the failure to reach a closed backend")
	}
}
