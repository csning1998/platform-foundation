package operatorops

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
)

// layersDir is the terraform/layers directory of the repository, relative to this package.
const layersDir = "../../../../terraform/layers"

// writeLayerFiles writes each file of files below a new layer directory and returns the directory.
func writeLayerFiles(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, content := range files {
		err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o600)
		if err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	return dir
}

func TestReadOperatorSubject_ParsesValidDeclarations(t *testing.T) {
	cases := []struct {
		name  string
		files map[string]string
		want  OperatorSubject
	}{
		{
			name: "locals.tf",
			files: map[string]string{"locals.tf": `locals {
  terraform_operator_subject = { service = "harbor-origin", component = "frontend" }
  terraform_operator         = local.state.x[local.terraform_operator_subject.service]
}
`},
			want: OperatorSubject{Service: "harbor-origin", Component: "frontend"},
		},
		{
			name: "another file among several locals blocks",
			files: map[string]string{
				"locals.tf":    "locals {\n  state = {}\n}\n",
				"operator.tf":  "locals {\n  terraform_operator_subject = {\n    service   = \"spire\"\n    component = \"child\"\n  }\n}\n",
				"variables.tf": "variable \"terraform_operator_subject\" {\n  default = { service = \"x\", component = \"y\" }\n}\n",
			},
			want: OperatorSubject{Service: "spire", Component: "child"},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, found, err := ReadOperatorSubject(writeLayerFiles(t, c.files))
			if err != nil || !found || got != c.want {
				t.Errorf("ReadOperatorSubject = %+v, %v, %v, want %+v, true, nil", got, found, err, c.want)
			}
		})
	}
}

func TestReadOperatorSubject_ReportsLayerWithoutSubject(t *testing.T) {
	for name, files := range map[string]map[string]string{
		"no locals":          {"main.tf": "resource \"terraform_data\" \"x\" {}\n"},
		"other locals":       {"locals.tf": "locals {\n  terraform_operator = {}\n}\n"},
		"tfvars only":        {"terraform.tfvars": "terraform_operator_subject = { service = \"x\", component = \"y\" }\n"},
		"empty layer":        {},
		"variable not local": {"variables.tf": "variable \"terraform_operator_subject\" {}\n"},
	} {
		t.Run(name, func(t *testing.T) {
			got, found, err := ReadOperatorSubject(writeLayerFiles(t, files))
			if err != nil || found {
				t.Errorf("ReadOperatorSubject = %+v, %v, %v, want not found and nil", got, found, err)
			}
		})
	}
}

func TestReadOperatorSubject_RejectsInvalidDeclaration(t *testing.T) {
	for name, files := range map[string]map[string]string{
		"reference":      {"locals.tf": "locals {\n  terraform_operator_subject = { service = local.service, component = \"frontend\" }\n}\n"},
		"template":       {"locals.tf": "locals {\n  terraform_operator_subject = { service = \"${local.s}\", component = \"frontend\" }\n}\n"},
		"missing field":  {"locals.tf": "locals {\n  terraform_operator_subject = { service = \"keycloak\" }\n}\n"},
		"extra field":    {"locals.tf": "locals {\n  terraform_operator_subject = { service = \"keycloak\", component = \"frontend\", owner = \"x\" }\n}\n"},
		"number field":   {"locals.tf": "locals {\n  terraform_operator_subject = { service = \"keycloak\", component = 1 }\n}\n"},
		"empty field":    {"locals.tf": "locals {\n  terraform_operator_subject = { service = \"\", component = \"frontend\" }\n}\n"},
		"string literal": {"locals.tf": "locals {\n  terraform_operator_subject = \"keycloak-frontend\"\n}\n"},
		"declared twice": {"a.tf": "locals {\n  terraform_operator_subject = { service = \"a\", component = \"b\" }\n}\n", "b.tf": "locals {\n  terraform_operator_subject = { service = \"a\", component = \"b\" }\n}\n"},
	} {
		t.Run(name, func(t *testing.T) {
			got, found, err := ReadOperatorSubject(writeLayerFiles(t, files))
			if !errors.Is(err, ErrInvalidOperatorSubject) {
				t.Errorf("ReadOperatorSubject = %+v, %v, %v, want ErrInvalidOperatorSubject", got, found, err)
			}
		})
	}
}

func TestReadOperatorSubject_RejectsSyntaxError(t *testing.T) {
	dir := writeLayerFiles(t, map[string]string{"locals.tf": "locals {\n  terraform_operator_subject = {\n"})
	_, _, err := ReadOperatorSubject(dir)
	if err == nil || !strings.Contains(err.Error(), "locals.tf") {
		t.Errorf("ReadOperatorSubject error = %v, want a parse error which names locals.tf", err)
	}
}

// operatorTargetRe matches the literal service and component of each operator target, after the owner of the target.
var operatorTargetRe = regexp.MustCompile(
	`\{\s*owner\s*=\s*[^,]+,\s*service\s*=\s*"([a-z0-9-]+)",\s*component\s*=\s*"([a-z0-9-]+)"\s*\}`)

// operatorTargetLists names the layer and the local of the operator targets of each SPIRE server.
var operatorTargetLists = []struct{ layer, local string }{
	{"provision-spire-parent", "_spire_parent_operator_targets"},
	{"security-vault-downstream-tenants", "_spire_child_operator_targets"},
}

// readOperatorTargets returns the operator targets which the SPIRE Parent and the SPIRE Child register.
func readOperatorTargets(t *testing.T) map[OperatorSubject]bool {
	t.Helper()
	targets := map[OperatorSubject]bool{}
	for _, list := range operatorTargetLists {
		content, err := os.ReadFile(filepath.Join(layersDir, list.layer, "locals.tf"))
		if err != nil {
			t.Fatalf("read %s locals: %v", list.layer, err)
		}
		start := strings.Index(string(content), list.local+" = {")
		if start < 0 {
			t.Fatalf("%s declares no %s block", list.layer, list.local)
		}
		end := strings.Index(string(content)[start:], "\n  }\n")
		if end < 0 {
			t.Fatalf("%s of %s has no closing brace", list.local, list.layer)
		}
		matches := operatorTargetRe.FindAllStringSubmatch(string(content)[start:start+end], -1)
		if len(matches) == 0 {
			t.Fatalf("%s of %s holds no target", list.local, list.layer)
		}
		for _, m := range matches {
			subject := OperatorSubject{Service: m[1], Component: m[2]}
			if targets[subject] {
				t.Errorf("%s of %s registers %+v, which the other SPIRE server also registers", list.local, list.layer, subject)
			}
			targets[subject] = true
		}
	}
	return targets
}

// layerFacts holds what the drift rules inspect of one layer of the repository.
type layerFacts struct {
	name    string
	source  string
	subject OperatorSubject
	found   bool
	err     error
}

func (f layerFacts) isJWTLayer() bool { return strings.Contains(f.source, "auth_login_jwt") }

// readLayerFacts reads every .tf file of the layer at dir and its terraform_operator_subject.
func readLayerFacts(t *testing.T, dir string) layerFacts {
	t.Helper()
	files, err := filepath.Glob(filepath.Join(dir, "*.tf"))
	if err != nil {
		t.Fatalf("glob %s: %v", dir, err)
	}
	var source strings.Builder
	for _, file := range files {
		content, err := os.ReadFile(file)
		if err != nil {
			t.Fatalf("read %s: %v", file, err)
		}
		source.Write(content)
	}
	f := layerFacts{name: filepath.Base(dir), source: source.String()}
	f.subject, f.found, f.err = ReadOperatorSubject(dir)
	return f
}

// TestReadOperatorSubject_MatchesRepositoryLayers enforces the Day 0 declaration of every layer of the repository.
func TestReadOperatorSubject_MatchesRepositoryLayers(t *testing.T) {
	targets := readOperatorTargets(t)
	rules := []struct {
		isViolated func(f layerFacts) bool
		message    string
	}{
		{func(f layerFacts) bool { return f.err != nil }, "reads with an error"},
		{func(f layerFacts) bool { return f.isJWTLayer() && !f.found }, "declares auth_login_jwt without " + SubjectLocal},
		{func(f layerFacts) bool { return !f.isJWTLayer() && f.found }, "declares " + SubjectLocal + " without auth_login_jwt"},
		{func(f layerFacts) bool { return f.found && !targets[f.subject] }, "declares a subject which neither SPIRE server registers as an operator"},
		{func(f layerFacts) bool {
			return f.isJWTLayer() && !strings.Contains(f.source, "local.terraform_operator.auth_mount")
		}, "logs in without local.terraform_operator.auth_mount"},
		{func(f layerFacts) bool {
			return f.isJWTLayer() && !strings.Contains(f.source, "local.terraform_operator.role_name")
		}, "logs in without local.terraform_operator.role_name"},
	}

	dirs, err := filepath.Glob(filepath.Join(layersDir, "*"))
	if err != nil || len(dirs) == 0 {
		t.Fatalf("glob %s: %d layers, %v", layersDir, len(dirs), err)
	}
	for _, dir := range dirs {
		f := readLayerFacts(t, dir)
		for _, rule := range rules {
			if rule.isViolated(f) {
				t.Errorf("layer %s %s: subject %+v, error %v", f.name, rule.message, f.subject, f.err)
			}
		}
	}
}

func TestResolveWrapperPath_BuildsExpectedPath(t *testing.T) {
	cfg := Config{WrapperDir: "/usr/local/bin", OwnerCode: "example-platform"}
	cases := []struct {
		subject OperatorSubject
		want    string
	}{
		{OperatorSubject{"keycloak", "frontend"}, "/usr/local/bin/spire-fetch-example-platform-terraform-operator-keycloak-frontend"},
		{OperatorSubject{"harbor-origin", "frontend"}, "/usr/local/bin/spire-fetch-example-platform-terraform-operator-harbor-origin-frontend"},
		{OperatorSubject{"spire", "child"}, "/usr/local/bin/spire-fetch-example-platform-terraform-operator-spire-child"},
	}
	for _, c := range cases {
		got := ResolveWrapperPath(cfg, c.subject)
		if got != c.want {
			t.Errorf("ResolveWrapperPath(%+v) = %q, want %q", c.subject, got, c.want)
		}
	}
}

// writeFakeExecutable writes an executable script below dir which stands in for a wrapper or for terraform.
func writeFakeExecutable(t *testing.T, dir, name, body string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	err := os.WriteFile(path, []byte("#!/bin/sh\n"+body+"\n"), 0o700)
	if err != nil {
		t.Fatalf("write fake executable: %v", err)
	}
	return path
}

// isPathPresent reports whether path exists, which the fixtures use to detect a wrapper run.
func isPathPresent(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func TestFetchJWT_ExtractsJWTToken(t *testing.T) {
	cases := []struct {
		name string
		body string
		want string
	}{
		{"jwt field", `printf '{"jwt":"eyJhbGciOi.payload.signature"}\n'`, "eyJhbGciOi.payload.signature"},
		{"extra fields", `printf '{"jwt":"eyJ.a.b","expires_at":1}'`, "eyJ.a.b"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			wrapper := writeFakeExecutable(t, t.TempDir(), "wrapper", c.body)
			got, err := FetchJWT(context.Background(), wrapper)
			if err != nil || got != c.want {
				t.Errorf("FetchJWT = %q, %v, want %q, nil", got, err, c.want)
			}
		})
	}
}

func TestFetchJWT_RejectsOutputWithoutJWT(t *testing.T) {
	for _, c := range []struct{ name, body string }{
		{"empty jwt", `printf '{"jwt":""}'`},
		{"null jwt", `printf '{"jwt":null}'`},
		{"absent jwt", `printf '{"token":"eyJ.a.b"}'`},
		{"empty output", `true`},
	} {
		t.Run(c.name, func(t *testing.T) {
			wrapper := writeFakeExecutable(t, t.TempDir(), "wrapper", c.body)
			got, err := FetchJWT(context.Background(), wrapper)
			if !errors.Is(err, ErrJWTMissing) || got != "" {
				t.Errorf("FetchJWT = %q, %v, want \"\", ErrJWTMissing", got, err)
			}
		})
	}
}

// TestFetchJWT_KeepsOutputOutOfErrorMessage covers output which fails to parse and MAY still hold a token.
func TestFetchJWT_KeepsOutputOutOfErrorMessage(t *testing.T) {
	for _, c := range []struct{ name, body string }{
		{"truncated object", `printf '{"jwt":"eyJsecret.payload.sig"'`},
		{"non-string jwt", `printf '{"jwt":["eyJsecret.payload.sig"]}'`},
	} {
		t.Run(c.name, func(t *testing.T) {
			wrapper := writeFakeExecutable(t, t.TempDir(), "wrapper", c.body)
			got, err := FetchJWT(context.Background(), wrapper)
			if err == nil || got != "" {
				t.Fatalf("FetchJWT = %q, %v, want \"\" and a parse error", got, err)
			}
			if strings.Contains(err.Error(), "eyJsecret") {
				t.Errorf("FetchJWT error = %q, want no wrapper output in the message", err)
			}
		})
	}
}

func TestFetchJWT_ReportsWrapperFailure(t *testing.T) {
	wrapper := writeFakeExecutable(t, t.TempDir(), "wrapper",
		`echo "spire-agent exited 1: connect: no such file or directory" >&2; exit 1`)
	_, err := FetchJWT(context.Background(), wrapper)
	if err == nil || errors.Is(err, ErrJWTMissing) {
		t.Fatalf("FetchJWT error = %v, want the wrapper failure", err)
	}
	if !strings.Contains(err.Error(), "connect: no such file or directory") {
		t.Errorf("FetchJWT error = %q, want the stderr of the wrapper", err)
	}
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) || exitErr.ExitCode() != 1 {
		t.Errorf("FetchJWT error = %v, want exit status 1 in the chain", err)
	}
}

func TestFetchJWT_RejectsMissingWrapper(t *testing.T) {
	dir := t.TempDir()
	nonExecutable := filepath.Join(dir, "non-executable")
	err := os.WriteFile(nonExecutable, []byte("#!/bin/sh\n"), 0o600)
	if err != nil {
		t.Fatalf("write non-executable wrapper: %v", err)
	}
	for name, path := range map[string]string{
		"absent":         filepath.Join(dir, "absent"),
		"non-executable": nonExecutable,
		"directory":      dir,
	} {
		t.Run(name, func(t *testing.T) {
			_, err := FetchJWT(context.Background(), path)
			if !errors.Is(err, ErrWrapperMissing) {
				t.Fatalf("FetchJWT(%s) error = %v, want ErrWrapperMissing", name, err)
			}
			if !strings.Contains(err.Error(), path) {
				t.Errorf("FetchJWT(%s) error = %q, want the wrapper path in the message", name, err)
			}
		})
	}
}

func TestBuildTerraformEnv_InjectsJWTToken(t *testing.T) {
	cases := []struct {
		name string
		base []string
		want []string
	}{
		{"absent key", []string{"PATH=/bin"}, []string{"PATH=/bin", JWTEnvKey + "=new"}},
		{"stale key", []string{JWTEnvKey + "=old", "PATH=/bin"}, []string{"PATH=/bin", JWTEnvKey + "=new"}},
		{"duplicate keys", []string{JWTEnvKey + "=a", "PATH=/bin", JWTEnvKey + "=b"}, []string{"PATH=/bin", JWTEnvKey + "=new"}},
		{"prefix of another key", []string{JWTEnvKey + "_X=keep"}, []string{JWTEnvKey + "_X=keep", JWTEnvKey + "=new"}},
		{"empty base", nil, []string{JWTEnvKey + "=new"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			base := slices.Clone(c.base)
			got := BuildTerraformEnv(base, "new")
			if !slices.Equal(got, c.want) {
				t.Errorf("BuildTerraformEnv = %q, want %q", got, c.want)
			}
			if !slices.Equal(base, c.base) {
				t.Errorf("BuildTerraformEnv mutated base to %q", base)
			}
		})
	}
}

// prepareFixture holds a layer directory, a wrapper directory, and a PATH with a fake terraform.
type prepareFixture struct {
	cfg       Config
	layerDir  string
	terraform string
	marker    string
}

// keycloakSubjectLocals declares the operator of keycloak/frontend in a layer whose name carries neither field.
const keycloakSubjectLocals = "locals {\n  terraform_operator_subject = { service = \"keycloak\", component = \"frontend\" }\n}\n"

func newPrepareFixture(t *testing.T, locals string) prepareFixture {
	t.Helper()
	root := t.TempDir()
	f := prepareFixture{
		cfg:      Config{WrapperDir: filepath.Join(root, "wrappers"), OwnerCode: "example-platform"},
		layerDir: filepath.Join(root, "layers", "any-layer"),
		marker:   filepath.Join(root, "wrapper-ran"),
	}
	binDir := filepath.Join(root, "bin")
	for _, dir := range []string{f.layerDir, f.cfg.WrapperDir, binDir} {
		err := os.MkdirAll(dir, 0o700)
		if err != nil {
			t.Fatalf("mkdir %s: %v", dir, err)
		}
	}
	err := os.WriteFile(filepath.Join(f.layerDir, "locals.tf"), []byte(locals), 0o600)
	if err != nil {
		t.Fatalf("write layer locals: %v", err)
	}
	writeFakeExecutable(t, f.cfg.WrapperDir, "spire-fetch-example-platform-terraform-operator-keycloak-frontend",
		`touch "`+f.marker+`"; printf '{"jwt":"eyJ.keycloak.sig"}'`)
	f.terraform = writeFakeExecutable(t, binDir, "terraform", "exit 0")
	t.Setenv("PATH", binDir)
	return f
}

func TestPrepareTerraform_PreparesValidInvocation(t *testing.T) {
	f := newPrepareFixture(t, keycloakSubjectLocals)
	environ := []string{"PATH=" + filepath.Dir(f.terraform), "VAULT_TOKEN=tenant"}

	got, err := PrepareTerraform(context.Background(), f.cfg, f.layerDir, []string{"plan", "-out=tfplan"}, environ)
	if err != nil {
		t.Fatalf("PrepareTerraform: %v", err)
	}
	if got.Path != f.terraform {
		t.Errorf("Path = %q, want %q", got.Path, f.terraform)
	}
	wantArgs := []string{"terraform", "plan", "-out=tfplan"}
	if !slices.Equal(got.Args, wantArgs) {
		t.Errorf("Args = %q, want %q", got.Args, wantArgs)
	}
	wantEnv := append(slices.Clone(environ), JWTEnvKey+"=eyJ.keycloak.sig")
	if !slices.Equal(got.Env, wantEnv) {
		t.Errorf("Env = %q, want %q", got.Env, wantEnv)
	}
}

// TestPrepareTerraform_RunsLayerWithoutJWTLoginPlainly covers a stale JWT-SVID of the shell, which MUST NOT reach another layer.
func TestPrepareTerraform_RunsLayerWithoutJWTLoginPlainly(t *testing.T) {
	f := newPrepareFixture(t, "locals {\n  state = {}\n}\n")
	environ := []string{JWTEnvKey + "=eyJ.stale.sig", "PATH=" + filepath.Dir(f.terraform)}

	got, err := PrepareTerraform(context.Background(), f.cfg, f.layerDir, []string{"plan"}, environ)
	if err != nil {
		t.Fatalf("PrepareTerraform: %v", err)
	}
	if got.Path != f.terraform {
		t.Errorf("Path = %q, want %q", got.Path, f.terraform)
	}
	wantArgs := []string{"terraform", "plan"}
	if !slices.Equal(got.Args, wantArgs) {
		t.Errorf("Args = %q, want %q", got.Args, wantArgs)
	}
	wantEnv := []string{"PATH=" + filepath.Dir(f.terraform)}
	if !slices.Equal(got.Env, wantEnv) {
		t.Errorf("Env = %q, want %q", got.Env, wantEnv)
	}
	if isPathPresent(f.marker) {
		t.Error("PrepareTerraform ran a wrapper for a layer without JWT login")
	}
}

func TestPrepareTerraform_RejectsInvalidSubject(t *testing.T) {
	f := newPrepareFixture(t, "locals {\n  terraform_operator_subject = { service = local.s, component = \"frontend\" }\n}\n")

	_, err := PrepareTerraform(context.Background(), f.cfg, f.layerDir, []string{"plan"}, nil)
	if !errors.Is(err, ErrInvalidOperatorSubject) {
		t.Errorf("PrepareTerraform error = %v, want ErrInvalidOperatorSubject", err)
	}
	if isPathPresent(f.marker) {
		t.Error("PrepareTerraform ran a wrapper for an invalid subject")
	}
}

func TestPrepareTerraform_RejectsMissingTerraform(t *testing.T) {
	f := newPrepareFixture(t, keycloakSubjectLocals)
	t.Setenv("PATH", t.TempDir())

	_, err := PrepareTerraform(context.Background(), f.cfg, f.layerDir, []string{"plan"}, nil)
	if !errors.Is(err, exec.ErrNotFound) {
		t.Errorf("PrepareTerraform error = %v, want exec.ErrNotFound", err)
	}
	if isPathPresent(f.marker) {
		t.Error("PrepareTerraform fetched a JWT-SVID although terraform is absent")
	}
}
