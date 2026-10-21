// Package clusterops opens an operator session on a Talos cluster of the service catalog, with the kubeconfig and the
// talosconfig which the platform layer of the cluster writes into the Vault.
package clusterops

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	vaultapi "github.com/hashicorp/vault/api"

	"platform/internal/config"
	"platform/internal/operatorops"
)

var (
	// ErrInvalidTarget reports an argument other than <service>/<component> of catalog words.
	ErrInvalidTarget = errors.New("clusterops: the target MUST be <service>/<component> of lowercase words joined by single hyphens")
	// ErrUnknownTarget reports a target without a Terraform operator on the Downstream Vault.
	ErrUnknownTarget = errors.New("clusterops: the target has no Terraform operator")
	// ErrClusterConfigMissing reports a cluster without a cluster-config leaf, for example a cluster of the VM runtime.
	ErrClusterConfigMissing = errors.New("clusterops: the Vault holds no cluster-config of the target")
	// ErrProxyEnvironmentMissing reports a shell without the environment of the platform-foundation Vault Proxy.
	ErrProxyEnvironmentMissing = errors.New("clusterops: VAULT_ADDR, VAULT_TOKEN, VAULT_CLIENT_CERT, or VAULT_CLIENT_KEY is empty, allow the .envrc with direnv allow or run eval \"$(vault-proxy-env " + config.VaultProxyIdentity + ")\"")
)

// catalogWordsRe matches a service or component name of the service catalog.
var catalogWordsRe = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)

// ClusterConfig is the Vault instance, the KV v2 mount, and the KV path of the cluster-config leaf.
type ClusterConfig struct {
	Vault   string
	KVMount string
	KVPath  string
}

// Operator holds the JWT login coordinates of the Terraform operator of one component and its cluster-config leaf.
type Operator struct {
	AuthMount     string
	RoleName      string
	ClusterConfig ClusterConfig
}

// Coordinates holds the Downstream Vault address, its CA chain, and the operators keyed by service and component.
type Coordinates struct {
	Address    string
	CACertPath string
	Operators  map[string]map[string]Operator
}

// Credential holds the decoded kubeconfig and the base64 Talos client credentials of a cluster.
type Credential struct {
	Kubeconfig []byte
	TalosCA    string
	TalosCert  string
	TalosKey   string
}

// ParseTarget returns the subject of arg, which MUST be <service>/<component>.
func ParseTarget(arg string) (operatorops.OperatorSubject, error) {
	service, component, found := strings.Cut(arg, "/")
	if !found || !catalogWordsRe.MatchString(service) || !catalogWordsRe.MatchString(component) {
		return operatorops.OperatorSubject{}, fmt.Errorf("%w: %q", ErrInvalidTarget, arg)
	}
	return operatorops.OperatorSubject{Service: service, Component: component}, nil
}

// formatTarget returns <service>/<component> of target.
func formatTarget(target operatorops.OperatorSubject) string {
	return target.Service + "/" + target.Component
}

// operatorOutput is one entry of output downstream_vault_operators.
type operatorOutput struct {
	AuthMount     string `json:"auth_mount"`
	RoleName      string `json:"role_name"`
	ClusterConfig *struct {
		Vault   string `json:"vault"`
		KVMount string `json:"kv_mount"`
		KVPath  string `json:"kv_path"`
	} `json:"cluster_config"`
}

// terraformOutputs maps each output name of terraform output -json to its raw value.
type terraformOutputs map[string]struct {
	Value json.RawMessage `json:"value"`
}

// decode unmarshals the value of output name into target, and rejects an absent or null output.
func (o terraformOutputs) decode(name string, target any) error {
	output, ok := o[name]
	if !ok || len(output.Value) == 0 || string(output.Value) == "null" {
		return fmt.Errorf("clusterops: terraform output lacks %s, apply security-vault-downstream-tenants first", name)
	}
	err := json.Unmarshal(output.Value, target)
	if err != nil {
		return fmt.Errorf("clusterops: parse terraform output %s: %w", name, err)
	}
	return nil
}

// DecodeCoordinates returns the coordinates of the output of terraform output -json of security-vault-downstream-tenants.
func DecodeCoordinates(outputJSON []byte) (Coordinates, error) {
	var outputs terraformOutputs
	err := json.Unmarshal(outputJSON, &outputs)
	if err != nil {
		return Coordinates{}, fmt.Errorf("clusterops: parse terraform output: %w", err)
	}

	var c Coordinates
	var operators map[string]map[string]operatorOutput
	for _, output := range []struct {
		name   string
		target any
	}{
		{"downstream_vault_endpoint", &c.Address},
		{"downstream_vault_ca_cert_path", &c.CACertPath},
		{"downstream_vault_operators", &operators},
	} {
		err := outputs.decode(output.name, output.target)
		if err != nil {
			return Coordinates{}, err
		}
	}

	c.Operators = map[string]map[string]Operator{}
	for _, service := range slices.Sorted(maps.Keys(operators)) {
		c.Operators[service] = map[string]Operator{}
		for _, component := range slices.Sorted(maps.Keys(operators[service])) {
			op, err := convertOperator(service+"/"+component, operators[service][component])
			if err != nil {
				return Coordinates{}, err
			}
			c.Operators[service][component] = op
		}
	}
	return c, nil
}

// convertOperator returns the operator of one output entry, rejecting an entry without its login or its leaf.
func convertOperator(target string, op operatorOutput) (Operator, error) {
	if op.AuthMount == "" || op.RoleName == "" {
		return Operator{}, fmt.Errorf("clusterops: operator %s lacks its auth mount or role", target)
	}
	cc := op.ClusterConfig
	if cc == nil || cc.KVMount == "" || cc.KVPath == "" {
		return Operator{}, fmt.Errorf("clusterops: operator %s lacks the KV mount or path of its cluster-config", target)
	}
	if cc.Vault != "bastion" && cc.Vault != "downstream" {
		return Operator{}, fmt.Errorf("clusterops: operator %s names Vault %q, want bastion or downstream", target, cc.Vault)
	}
	return Operator{
		AuthMount:     op.AuthMount,
		RoleName:      op.RoleName,
		ClusterConfig: ClusterConfig{Vault: cc.Vault, KVMount: cc.KVMount, KVPath: cc.KVPath},
	}, nil
}

// ReadCoordinates runs terraform output -json in tenantsLayerDir and returns the coordinates of the output.
func ReadCoordinates(ctx context.Context, tenantsLayerDir string) (Coordinates, error) {
	var stdout, stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, "terraform", "-chdir="+tenantsLayerDir, "output", "-json")
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	if err != nil {
		return Coordinates{}, fmt.Errorf("clusterops: terraform output of %s: %w: %s",
			filepath.Base(tenantsLayerDir), err, strings.TrimSpace(stderr.String()))
	}
	return DecodeCoordinates(stdout.Bytes())
}

// ResolveOperator returns the operator of target.
func (c Coordinates) ResolveOperator(target operatorops.OperatorSubject) (Operator, error) {
	op, ok := c.Operators[target.Service][target.Component]
	if !ok {
		targets := c.ListTargets()
		known := make([]string, 0, len(targets))
		for _, t := range targets {
			known = append(known, formatTarget(t))
		}
		return Operator{}, fmt.Errorf("%w: %s, known targets: %s", ErrUnknownTarget, formatTarget(target), strings.Join(known, ", "))
	}
	return op, nil
}

// ListTargets returns every target of the coordinates, ordered by service and component.
func (c Coordinates) ListTargets() []operatorops.OperatorSubject {
	var targets []operatorops.OperatorSubject
	for _, service := range slices.Sorted(maps.Keys(c.Operators)) {
		for _, component := range slices.Sorted(maps.Keys(c.Operators[service])) {
			targets = append(targets, operatorops.OperatorSubject{Service: service, Component: component})
		}
	}
	return targets
}

// newVaultClient returns a client of address which trusts caCertPath alone. The client drops the token and the
// namespace which the Vault SDK reads from the environment, keeping the Proxy placeholder token off another Vault.
func newVaultClient(address string, tlsConfig vaultapi.TLSConfig) (*vaultapi.Client, error) {
	cfg := vaultapi.DefaultConfig()
	if cfg.Error != nil {
		return nil, fmt.Errorf("clusterops: Vault client configuration: %w", cfg.Error)
	}
	cfg.Address = address
	// DefaultConfig loads VAULT_CLIENT_CERT of the process, which the Downstream Vault MUST NOT receive.
	cfg.HttpClient.Transport.(*http.Transport).TLSClientConfig.GetClientCertificate = nil
	err := cfg.ConfigureTLS(&tlsConfig)
	if err != nil {
		return nil, fmt.Errorf("clusterops: Vault TLS of %s: %w", address, err)
	}
	client, err := vaultapi.NewClient(cfg)
	if err != nil {
		return nil, fmt.Errorf("clusterops: Vault client of %s: %w", address, err)
	}
	client.ClearToken()
	client.ClearNamespace()
	return client, nil
}

// LoginDownstream logs in to the Downstream Vault at address with jwt, verifying the listener against caCertPath.
func LoginDownstream(ctx context.Context, address, caCertPath string, op Operator, jwt string) (*vaultapi.Client, error) {
	client, err := newVaultClient(address, vaultapi.TLSConfig{CACert: caCertPath})
	if err != nil {
		return nil, err
	}
	secret, err := client.Logical().WriteWithContext(ctx, "auth/"+op.AuthMount+"/login", map[string]any{
		"role": op.RoleName,
		"jwt":  jwt,
	})
	if err != nil {
		return nil, fmt.Errorf("clusterops: log in to the Downstream Vault as %s: %w", op.RoleName, err)
	}
	if secret == nil || secret.Auth == nil || secret.Auth.ClientToken == "" {
		return nil, fmt.Errorf("clusterops: the Downstream Vault returned no token for %s", op.RoleName)
	}
	client.SetToken(secret.Auth.ClientToken)
	return client, nil
}

// NewBastionClient returns a Bastion Vault client of the Vault Proxy environment which getenv reads.
// The Proxy listener admits a request with the client certificate of the identity alone.
func NewBastionClient(getenv func(string) string) (*vaultapi.Client, error) {
	address, token := getenv("VAULT_ADDR"), getenv("VAULT_TOKEN")
	clientCert, clientKey := getenv("VAULT_CLIENT_CERT"), getenv("VAULT_CLIENT_KEY")
	if address == "" || token == "" || clientCert == "" || clientKey == "" {
		return nil, ErrProxyEnvironmentMissing
	}
	client, err := newVaultClient(address, vaultapi.TLSConfig{CACert: getenv("VAULT_CACERT"), ClientCert: clientCert, ClientKey: clientKey})
	if err != nil {
		return nil, err
	}
	client.SetToken(token)
	return client, nil
}

// ReadCredential reads the cluster-config leaf of cc through client. An error names a field and never a value.
func ReadCredential(ctx context.Context, client *vaultapi.Client, cc ClusterConfig) (Credential, error) {
	secret, err := client.KVv2(cc.KVMount).Get(ctx, cc.KVPath)
	if errors.Is(err, vaultapi.ErrSecretNotFound) {
		return Credential{}, fmt.Errorf("%w: %s/%s on the %s Vault", ErrClusterConfigMissing, cc.KVMount, cc.KVPath, cc.Vault)
	}
	if err != nil {
		return Credential{}, fmt.Errorf("clusterops: read %s/%s: %w", cc.KVMount, cc.KVPath, err)
	}

	fields := map[string]string{}
	for _, name := range []string{"content_b64", "talos_ca_certificate_b64", "talos_client_certificate_b64", "talos_client_key_b64"} {
		value, ok := secret.Data[name].(string)
		if !ok || value == "" {
			return Credential{}, fmt.Errorf("clusterops: %s/%s lacks field %s", cc.KVMount, cc.KVPath, name)
		}
		_, err := base64.StdEncoding.DecodeString(value)
		if err != nil {
			return Credential{}, fmt.Errorf("clusterops: %s/%s field %s is not base64: %w", cc.KVMount, cc.KVPath, name, err)
		}
		fields[name] = value
	}
	kubeconfig, err := base64.StdEncoding.DecodeString(fields["content_b64"])
	if err != nil {
		return Credential{}, fmt.Errorf("clusterops: %s/%s field content_b64 is not base64: %w", cc.KVMount, cc.KVPath, err)
	}
	return Credential{
		Kubeconfig: kubeconfig,
		TalosCA:    fields["talos_ca_certificate_b64"],
		TalosCert:  fields["talos_client_certificate_b64"],
		TalosKey:   fields["talos_client_key_b64"],
	}, nil
}

// RenderTalosconfig returns the talosconfig of target with nodes as both endpoints and nodes.
func RenderTalosconfig(target operatorops.OperatorSubject, nodes []string, cred Credential) string {
	name := formatTarget(target)
	var b strings.Builder
	b.WriteString("context: ")
	b.WriteString(name)
	b.WriteString("\ncontexts:\n  ")
	b.WriteString(name)
	b.WriteString(":\n")
	if len(nodes) > 0 {
		list := "[" + strings.Join(nodes, ", ") + "]"
		b.WriteString("    endpoints: ")
		b.WriteString(list)
		b.WriteString("\n    nodes: ")
		b.WriteString(list)
		b.WriteString("\n")
	}
	b.WriteString("    ca: ")
	b.WriteString(cred.TalosCA)
	b.WriteString("\n    crt: ")
	b.WriteString(cred.TalosCert)
	b.WriteString("\n    key: ")
	b.WriteString(cred.TalosKey)
	b.WriteString("\n")
	return b.String()
}

// ListNodeAddresses returns the InternalIP of every node which the API server behind kubeconfigPath reports.
// The cluster itself supplies the addresses, which keeps the Talos endpoints out of any second source.
func ListNodeAddresses(ctx context.Context, kubeconfigPath string) ([]string, error) {
	var stdout, stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, "kubectl", "--kubeconfig", kubeconfigPath, "--request-timeout=10s",
		"get", "nodes", "-o", `jsonpath={range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}`)
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	if err != nil {
		return nil, fmt.Errorf("clusterops: list nodes: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return strings.Fields(stdout.String()), nil
}

// ResolveRuntimeDir returns XDG_RUNTIME_DIR, or the temporary directory when XDG_RUNTIME_DIR is empty.
func ResolveRuntimeDir(getenv func(string) string) string {
	dir := getenv("XDG_RUNTIME_DIR")
	if dir == "" {
		return os.TempDir()
	}
	return dir
}

// CreateSessionDir creates a private directory of one session below baseDir. The random name keeps concurrent
// sessions apart and leaves no predictable path in a shared temporary directory.
func CreateSessionDir(baseDir string) (string, error) {
	dir, err := os.MkdirTemp(baseDir, "platform-cluster-")
	if err != nil {
		return "", fmt.Errorf("clusterops: create session directory: %w", err)
	}
	return dir, nil
}

// WriteSessionFile writes content to name below the session directory dir with owner-only permissions.
func WriteSessionFile(dir, name string, content []byte) (string, error) {
	if name == "" || name == "." || name == ".." || name != filepath.Base(name) {
		return "", fmt.Errorf("clusterops: session file name %q leaves the session directory", name)
	}
	path := filepath.Join(dir, name)
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return "", fmt.Errorf("clusterops: create %s: %w", path, err)
	}
	_, err = file.Write(content)
	closeErr := file.Close()
	if err != nil || closeErr != nil {
		return "", fmt.Errorf("clusterops: write %s: %w", path, errors.Join(err, closeErr))
	}
	return path, nil
}

// BuildShellEnv returns base with KUBECONFIG, TALOSCONFIG, and PLATFORM_CLUSTER of the session in dir.
func BuildShellEnv(base []string, dir string, target operatorops.OperatorSubject) []string {
	env := slices.DeleteFunc(slices.Clone(base), func(kv string) bool {
		return strings.HasPrefix(kv, "KUBECONFIG=") || strings.HasPrefix(kv, "TALOSCONFIG=") || strings.HasPrefix(kv, "PLATFORM_CLUSTER=")
	})
	return append(env,
		"KUBECONFIG="+filepath.Join(dir, kubeconfigName),
		"TALOSCONFIG="+filepath.Join(dir, talosconfigName),
		"PLATFORM_CLUSTER="+formatTarget(target),
	)
}

// RunSession runs run with env and removes the session directory dir afterwards, whatever run returns.
func RunSession(ctx context.Context, dir string, env []string, run func(context.Context, []string) error) error {
	runErr := run(ctx, env)
	removeErr := os.RemoveAll(dir)
	if removeErr != nil {
		removeErr = fmt.Errorf("clusterops: remove session directory %s: %w", dir, removeErr)
	}
	return errors.Join(runErr, removeErr)
}
