package clusterops

import (
	"context"
	"errors"
	"os"
	"path/filepath"

	vaultapi "github.com/hashicorp/vault/api"

	"platform/internal/operatorops"
)

const (
	kubeconfigName  = "kubeconfig"
	talosconfigName = "talosconfig"
)

// Workstation contains the facts of the operator workstation which a cluster session reads.
type Workstation struct {
	// TenantsLayerDir is the directory of layer security-vault-downstream-tenants.
	TenantsLayerDir string
	// Operator locates the JWT-SVID wrappers of the Terraform operators.
	Operator operatorops.Config
	// Getenv reads the Vault Proxy environment and XDG_RUNTIME_DIR.
	Getenv func(string) string
}

// Session is the directory of the session files of one target and the node addresses which the API server reported.
type Session struct {
	Target   operatorops.OperatorSubject
	Dir      string
	Nodes    []string
	NodesErr error
}

// KubeconfigPath returns the path of the kubeconfig of the session.
func (s Session) KubeconfigPath() string { return filepath.Join(s.Dir, kubeconfigName) }

// OpenSession reads the cluster-config of the target which arg names and writes the files of a new session.
func (w Workstation) OpenSession(ctx context.Context, arg string) (Session, error) {
	target, err := ParseTarget(arg)
	if err != nil {
		return Session{}, err
	}
	coordinates, err := ReadCoordinates(ctx, w.TenantsLayerDir)
	if err != nil {
		return Session{}, err
	}
	cred, err := w.ReadTargetCredential(ctx, coordinates, target)
	if err != nil {
		return Session{}, err
	}
	return w.CreateSession(ctx, target, cred)
}

// ReadTargetCredential reads the cluster-config of target from the Vault which the coordinates name. The Downstream
// token remains inside this process, and the session receives the files alone.
func (w Workstation) ReadTargetCredential(ctx context.Context, coordinates Coordinates, target operatorops.OperatorSubject) (Credential, error) {
	op, err := coordinates.ResolveOperator(target)
	if err != nil {
		return Credential{}, err
	}
	client, err := w.loginClusterVault(ctx, coordinates, target, op)
	if err != nil {
		return Credential{}, err
	}
	return ReadCredential(ctx, client, op.ClusterConfig)
}

// loginClusterVault returns a client of the Vault which stores the cluster-config of target.
func (w Workstation) loginClusterVault(ctx context.Context, coordinates Coordinates, target operatorops.OperatorSubject, op Operator) (*vaultapi.Client, error) {
	if op.ClusterConfig.Vault == "bastion" {
		return NewBastionClient(w.Getenv)
	}
	jwt, err := operatorops.FetchJWT(ctx, operatorops.ResolveWrapperPath(w.Operator, target))
	if err != nil {
		return nil, err
	}
	return LoginDownstream(ctx, coordinates.Address, coordinates.CACertPath, op, jwt)
}

// CreateSession writes the kubeconfig and the talosconfig of target into a new session directory, and removes the
// directory when a write fails. An unreachable API server leaves the talosconfig without endpoints.
func (w Workstation) CreateSession(ctx context.Context, target operatorops.OperatorSubject, cred Credential) (Session, error) {
	dir, err := CreateSessionDir(ResolveRuntimeDir(w.Getenv))
	if err != nil {
		return Session{}, err
	}
	session, err := writeSessionFiles(ctx, Session{Target: target, Dir: dir}, cred)
	if err != nil {
		return Session{}, errors.Join(err, os.RemoveAll(dir))
	}
	return session, nil
}

// writeSessionFiles writes the kubeconfig, resolves the nodes through the kubeconfig, and writes the talosconfig.
func writeSessionFiles(ctx context.Context, session Session, cred Credential) (Session, error) {
	_, err := WriteSessionFile(session.Dir, kubeconfigName, cred.Kubeconfig)
	if err != nil {
		return session, err
	}
	session.Nodes, session.NodesErr = ListNodeAddresses(ctx, session.KubeconfigPath())
	talosconfig := RenderTalosconfig(session.Target, session.Nodes, cred)
	_, err = WriteSessionFile(session.Dir, talosconfigName, []byte(talosconfig))
	return session, err
}
