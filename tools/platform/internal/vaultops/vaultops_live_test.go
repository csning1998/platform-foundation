package vaultops

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func generateTestCACert(t *testing.T, targetPath string) {
	t.Helper()
	caKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	caTemplate := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "TestCA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageCertSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	f, err := os.Create(targetPath)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = f.Close() }()
	if err := pem.Encode(f, &pem.Block{Type: "CERTIFICATE", Bytes: caDER}); err != nil {
		t.Fatal(err)
	}
}

func newLiveTestPaths(t *testing.T, bastionAddr string) Paths {
	t.Helper()
	root := t.TempDir()
	caCert := filepath.Join(root, "ca.pem")
	generateTestCACert(t, caCert)
	return Paths{ProjectRoot: root, Home: t.TempDir(), bastionVaultAddr: bastionAddr, bastionVaultCACert: caCert}
}

func fakeSealStatusHandler(sequence ...bool) http.HandlerFunc {
	var call int32
	return func(w http.ResponseWriter, r *http.Request) {
		idx := int(atomic.AddInt32(&call, 1)) - 1
		sealed := sequence[len(sequence)-1]
		if idx < len(sequence) {
			sealed = sequence[idx]
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]interface{}{"initialized": true, "sealed": sealed})
	}
}

func TestGetBastionStatus_UnreachableConnectionRefused(t *testing.T) {
	p := newLiveTestPaths(t, "http://127.0.0.1:1")

	running, sealed, err := GetBastionStatus(context.Background(), p)
	if err != nil {
		t.Fatalf("GetBastionStatus: want nil error, got %v", err)
	}
	if running || sealed {
		t.Errorf("GetBastionStatus = (%v, %v), want (false, false)", running, sealed)
	}
}

func TestInspectBastionStatus_UnreachableReturnsZeroValue(t *testing.T) {
	p := newLiveTestPaths(t, "http://127.0.0.1:1")

	got := InspectBastionStatus(context.Background(), p)
	if got != (SealStatus{}) {
		t.Errorf("InspectBastionStatus = %+v, want zero value", got)
	}
}

func TestInspectBastionStatus_ReachableSealed(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/sys/seal-status", fakeSealStatusHandler(true))
	srv := httptest.NewServer(mux)
	defer srv.Close()

	p := newLiveTestPaths(t, srv.URL)

	got := InspectBastionStatus(context.Background(), p)
	want := SealStatus{Reachable: true, Initialized: true, Sealed: true}
	if got != want {
		t.Errorf("InspectBastionStatus = %+v, want %+v", got, want)
	}
}

func TestInspectBastionStatus_ReachableUnsealed(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/sys/seal-status", fakeSealStatusHandler(false))
	srv := httptest.NewServer(mux)
	defer srv.Close()

	p := newLiveTestPaths(t, srv.URL)

	got := InspectBastionStatus(context.Background(), p)
	want := SealStatus{Reachable: true, Initialized: true, Sealed: false}
	if got != want {
		t.Errorf("InspectBastionStatus = %+v, want %+v", got, want)
	}
}
