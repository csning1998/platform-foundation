package terraformops

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// retainedLayerPrefix marks the administration layers, which manage the GitLab project hosting every state.
const retainedLayerPrefix = "administration-"

// backendAddressRe matches the address of the GitLab HTTP backend block of a layer.
var backendAddressRe = regexp.MustCompile(`(?m)^\s*address\s*=\s*"(https://[^"]+/api/v4/projects/[0-9]+/terraform/state/[^"/]+)"`)

// ErrStateTokenMissing reports a shell without the GitLab token which the Vault Proxy environment exports.
var ErrStateTokenMissing = errors.New("terraformops: TF_HTTP_PASSWORD is empty, allow the .envrc with direnv allow")

// RemoteState is the GitLab HTTP backend state of one layer.
type RemoteState struct {
	Layer   string
	Address string
}

// ListPurgeableStates returns the backend state of every layer under terraformDir/layers except the administration
// layers, sorted by layer name.
func ListPurgeableStates(terraformDir string) ([]RemoteState, error) {
	layersDir := filepath.Join(terraformDir, "layers")
	entries, err := os.ReadDir(layersDir)
	if err != nil {
		return nil, fmt.Errorf("terraformops: read %s: %w", layersDir, err)
	}
	var states []RemoteState
	for _, entry := range entries {
		if !entry.IsDir() || strings.HasPrefix(entry.Name(), retainedLayerPrefix) {
			continue
		}
		address, err := readBackendAddress(filepath.Join(layersDir, entry.Name()))
		if err != nil {
			return nil, err
		}
		if address != "" {
			states = append(states, RemoteState{Layer: entry.Name(), Address: address})
		}
	}
	sort.Slice(states, func(i, j int) bool { return states[i].Layer < states[j].Layer })
	return states, nil
}

// readBackendAddress returns the GitLab HTTP backend address which a .tf file of layerDir declares, or "" without one.
func readBackendAddress(layerDir string) (string, error) {
	files, err := filepath.Glob(filepath.Join(layerDir, "*.tf"))
	if err != nil {
		return "", fmt.Errorf("terraformops: list the .tf files of %s: %w", filepath.Base(layerDir), err)
	}
	for _, file := range files {
		data, err := os.ReadFile(file)
		if err != nil {
			return "", fmt.Errorf("terraformops: read %s: %w", file, err)
		}
		if match := backendAddressRe.FindSubmatch(data); match != nil {
			return string(match[1]), nil
		}
	}
	return "", nil
}

// DeleteRemoteState deletes the state at state.Address together with every version of the state.
// An absent state counts as deleted. An error names the layer and the HTTP status, never the token.
func DeleteRemoteState(ctx context.Context, client *http.Client, token string, state RemoteState) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, state.Address, nil)
	if err != nil {
		return fmt.Errorf("terraformops: build the delete request of %s: %w", state.Layer, err)
	}
	req.Header.Set("PRIVATE-TOKEN", token)
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("terraformops: delete the state of %s: %w", state.Layer, err)
	}
	defer func() { _ = resp.Body.Close() }()
	switch resp.StatusCode {
	case http.StatusOK, http.StatusAccepted, http.StatusNoContent, http.StatusNotFound:
		return nil
	default:
		return fmt.Errorf("terraformops: delete the state of %s: HTTP %d", state.Layer, resp.StatusCode)
	}
}
