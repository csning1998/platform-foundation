// Package operatorops prepares the terraform invocation of a layer, which receives the JWT-SVID of the Terraform operator
// of its component when the Vault provider of the layer logs in with one.
package operatorops

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclparse"
	"github.com/hashicorp/hcl/v2/hclsyntax"
	"github.com/zclconf/go-cty/cty"
)

// DefaultWrapperDir is the directory where the play of provision-spire-parent installs the JWT-SVID wrappers.
const DefaultWrapperDir = "/usr/local/bin"

// JWTEnvKey is the variable which the Vault provider reads for block auth_login_jwt.
const JWTEnvKey = "TERRAFORM_VAULT_AUTH_JWT"

// SubjectLocal is the local which a layer of JWT-SVID login declares in place of a name parse of the layer.
const SubjectLocal = "terraform_operator_subject"

var (
	// ErrInvalidOperatorSubject reports a terraform_operator_subject other than one literal of service and component.
	ErrInvalidOperatorSubject = errors.New("operatorops: terraform_operator_subject MUST be one object literal of string literals service and component")
	// ErrWrapperMissing reports an absent or non-executable JWT-SVID wrapper.
	ErrWrapperMissing = errors.New("operatorops: JWT-SVID wrapper is missing, apply provision-spire-parent first")
	// ErrJWTMissing reports a wrapper output without a non-empty jwt field.
	ErrJWTMissing = errors.New("operatorops: wrapper output lacks a jwt field")
)

// OperatorSubject is the catalog service and component of a local Terraform operator.
type OperatorSubject struct {
	Service   string
	Component string
}

// Config contains the wrapper directory and the owner code which the wrapper names include.
type Config struct {
	WrapperDir string
	OwnerCode  string
}

// Invocation is the program, the argument vector, and the environment which replace the current process.
type Invocation struct {
	Path string
	Args []string
	Env  []string
}

// subjectDeclaration is one terraform_operator_subject attribute and the file which declares it.
type subjectDeclaration struct {
	file string
	expr hclsyntax.Expression
}

// ReadOperatorSubject returns the terraform_operator_subject of the layer at layerDir, and false when the layer
// declares none. The parse remains static because an evaluation would need the remote state of the layer.
func ReadOperatorSubject(layerDir string) (OperatorSubject, bool, error) {
	files, err := filepath.Glob(filepath.Join(layerDir, "*.tf"))
	if err != nil {
		return OperatorSubject{}, false, fmt.Errorf("operatorops: list %s: %w", layerDir, err)
	}

	parser := hclparse.NewParser()
	var declarations []subjectDeclaration
	for _, file := range files {
		found, err := findSubjectDeclarations(parser, file)
		if err != nil {
			return OperatorSubject{}, false, err
		}
		declarations = append(declarations, found...)
	}

	switch len(declarations) {
	case 0:
		return OperatorSubject{}, false, nil
	case 1:
		subject, err := decodeOperatorSubject(declarations[0].expr)
		if err != nil {
			return OperatorSubject{}, false, fmt.Errorf("%w: %s: %s", ErrInvalidOperatorSubject, declarations[0].file, err)
		}
		return subject, true, nil
	default:
		return OperatorSubject{}, false, fmt.Errorf("%w: %s declares it again", ErrInvalidOperatorSubject, declarations[1].file)
	}
}

// findSubjectDeclarations returns every terraform_operator_subject which a locals block of file declares.
func findSubjectDeclarations(parser *hclparse.Parser, file string) ([]subjectDeclaration, error) {
	parsed, diags := parser.ParseHCLFile(file)
	if diags.HasErrors() {
		return nil, fmt.Errorf("operatorops: parse %s: %w", file, diags)
	}
	body, ok := parsed.Body.(*hclsyntax.Body)
	if !ok {
		return nil, fmt.Errorf("operatorops: %s is not native HCL syntax", file)
	}
	var declarations []subjectDeclaration
	for _, block := range body.Blocks {
		attr, ok := block.Body.Attributes[SubjectLocal]
		if block.Type == "locals" && ok {
			declarations = append(declarations, subjectDeclaration{file: file, expr: attr.Expr})
		}
	}
	return declarations, nil
}

// decodeOperatorSubject returns the subject of expr, which MUST be an object of exactly two non-empty string literals.
func decodeOperatorSubject(expr hclsyntax.Expression) (OperatorSubject, error) {
	object, ok := expr.(*hclsyntax.ObjectConsExpr)
	if !ok {
		return OperatorSubject{}, errors.New("the value is not an object")
	}
	fields := map[string]string{}
	for _, item := range object.Items {
		key := hcl.ExprAsKeyword(item.KeyExpr)
		// A nil evaluation context rejects every reference and function call, which admits literals alone.
		value, diags := item.ValueExpr.Value(nil)
		if diags.HasErrors() || value.Type() != cty.String || value.IsNull() || value.AsString() == "" {
			return OperatorSubject{}, fmt.Errorf("field %q is not a non-empty string literal", key)
		}
		if _, exists := fields[key]; exists {
			return OperatorSubject{}, fmt.Errorf("field %q repeats", key)
		}
		fields[key] = value.AsString()
	}
	service, hasService := fields["service"]
	component, hasComponent := fields["component"]
	if len(fields) != 2 || !hasService || !hasComponent {
		return OperatorSubject{}, errors.New("the object MUST contain exactly the fields service and component")
	}
	return OperatorSubject{Service: service, Component: component}, nil
}

// ResolveWrapperPath returns the path of the JWT-SVID wrapper of subject below cfg.WrapperDir. The name follows the
// identity string of the operator, which provision-spire-parent composes from the same fields.
func ResolveWrapperPath(cfg Config, subject OperatorSubject) string {
	return filepath.Join(cfg.WrapperDir,
		"spire-fetch-"+cfg.OwnerCode+"-terraform-operator-"+subject.Service+"-"+subject.Component)
}

// FetchJWT runs the wrapper at wrapperPath and returns the jwt field of its JSON output.
// An error contains the stderr of the wrapper alone because the stdout MAY contain a token.
func FetchJWT(ctx context.Context, wrapperPath string) (string, error) {
	info, err := os.Stat(wrapperPath)
	if err != nil || info.IsDir() || info.Mode().Perm()&0o111 == 0 {
		return "", fmt.Errorf("%w: %s", ErrWrapperMissing, wrapperPath)
	}

	var stdout, stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, wrapperPath)
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err = cmd.Run()
	if err != nil {
		return "", fmt.Errorf("operatorops: run %s: %w: %s", wrapperPath, err, strings.TrimSpace(stderr.String()))
	}

	if len(bytes.TrimSpace(stdout.Bytes())) == 0 {
		return "", fmt.Errorf("%w: %s printed nothing", ErrJWTMissing, wrapperPath)
	}
	var output struct {
		JWT *string `json:"jwt"`
	}
	err = json.Unmarshal(stdout.Bytes(), &output)
	if err != nil {
		return "", fmt.Errorf("operatorops: parse the output of %s: %w", wrapperPath, err)
	}
	if output.JWT == nil || *output.JWT == "" {
		return "", fmt.Errorf("%w: %s", ErrJWTMissing, wrapperPath)
	}
	return *output.JWT, nil
}

// BuildTerraformEnv returns base with JWTEnvKey set to jwt.
func BuildTerraformEnv(base []string, jwt string) []string {
	return append(removeJWTEnv(base), JWTEnvKey+"="+jwt)
}

// removeJWTEnv returns a copy of base without JWTEnvKey.
func removeJWTEnv(base []string) []string {
	return slices.DeleteFunc(slices.Clone(base), func(kv string) bool {
		return strings.HasPrefix(kv, JWTEnvKey+"=")
	})
}

// PrepareTerraform returns the terraform invocation of the layer at layerDir, with the JWT-SVID of its operator
// when the layer logs in with one. Resolution of terraform precedes the wrapper run, hence a JWT-SVID never reaches an unstartable run.
func PrepareTerraform(ctx context.Context, cfg Config, layerDir string, args, environ []string) (Invocation, error) {
	terraform, err := exec.LookPath("terraform")
	if err != nil {
		return Invocation{}, fmt.Errorf("operatorops: %w", err)
	}
	inv := Invocation{
		Path: terraform,
		Args: append([]string{"terraform"}, args...),
		Env:  removeJWTEnv(environ),
	}

	subject, found, err := ReadOperatorSubject(layerDir)
	if err != nil {
		return Invocation{}, err
	}
	if !found {
		return inv, nil
	}
	jwt, err := FetchJWT(ctx, ResolveWrapperPath(cfg, subject))
	if err != nil {
		return Invocation{}, err
	}
	inv.Env = BuildTerraformEnv(environ, jwt)
	return inv, nil
}
