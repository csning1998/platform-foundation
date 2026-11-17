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

// httpBackendRe matches the GitLab HTTP backend block of a layer.
var httpBackendRe = regexp.MustCompile(`(?m)^\s*backend\s+"http"\s*\{`)

// ErrStateTokenMissing reports a shell without the GitLab token which the Vault Proxy environment exports.
var ErrStateTokenMissing = errors.New("terraformops: TF_HTTP_PASSWORD is empty, allow the .envrc with direnv allow")

// StateBaseEnvKey names the variable in which vault-proxy-env exports the GitLab state API URL of the repository.
const StateBaseEnvKey = "GITLAB_TERRAFORM_STATE_BASE"

// ErrStateBaseMissing reports a shell without the GitLab state API URL which the Vault Proxy environment exports.
var ErrStateBaseMissing = errors.New("terraformops: GITLAB_TERRAFORM_STATE_BASE is empty, allow the .envrc with direnv allow")

// BuildLayerBackendEnv returns the TF_HTTP address variables of the layer at layerDir, whose state name is the directory name.
func BuildLayerBackendEnv(stateBase, layerDir string) ([]string, error) {
	if stateBase == "" {
		return nil, ErrStateBaseMissing
	}
	address := buildStateAddress(stateBase, filepath.Base(layerDir))
	return []string{
		"TF_HTTP_ADDRESS=" + address,
		"TF_HTTP_LOCK_ADDRESS=" + address + "/lock",
		"TF_HTTP_UNLOCK_ADDRESS=" + address + "/lock",
	}, nil
}

// buildStateAddress returns the GitLab HTTP backend address of the state named layer.
func buildStateAddress(stateBase, layer string) string {
	return strings.TrimRight(stateBase, "/") + "/" + layer
}

// RemoteState is the GitLab HTTP backend state of one layer.
type RemoteState struct {
	Layer   string
	Address string
}

// ListPurgeableStates returns the backend state of every layer under terraformDir/layers except the administration
// layers, sorted by layer name. The state base is required once a layer declares the HTTP backend.
func ListPurgeableStates(terraformDir, stateBase string) ([]RemoteState, error) {
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
		declared, err := declaresHTTPBackend(filepath.Join(layersDir, entry.Name()))
		if err != nil {
			return nil, err
		}
		if !declared {
			continue
		}
		if stateBase == "" {
			return nil, ErrStateBaseMissing
		}
		states = append(states, RemoteState{Layer: entry.Name(), Address: buildStateAddress(stateBase, entry.Name())})
	}
	sort.Slice(states, func(i, j int) bool { return states[i].Layer < states[j].Layer })
	return states, nil
}

// declaresHTTPBackend reports whether a .tf file of layerDir declares the GitLab HTTP backend block.
func declaresHTTPBackend(layerDir string) (bool, error) {
	files, err := filepath.Glob(filepath.Join(layerDir, "*.tf"))
	if err != nil {
		return false, fmt.Errorf("terraformops: list the .tf files of %s: %w", filepath.Base(layerDir), err)
	}
	for _, file := range files {
		data, err := os.ReadFile(file)
		if err != nil {
			return false, fmt.Errorf("terraformops: read %s: %w", file, err)
		}
		if httpBackendRe.Match(data) {
			return true, nil
		}
	}
	return false, nil
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
