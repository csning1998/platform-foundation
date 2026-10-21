#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Execution PATH MUST include ~/.local/bin to discover user-installed toolchains.
export PATH="${HOME}/.local/bin:${PATH}"

# Analysis secrets and repository identifiers SHALL adhere to parent-group-governance schemas.
readonly cli_module="platform"
readonly -a cli_binaries=(
    platform
)
readonly sonar_project_key="csning1998-lab-platform-engineering-lab-platform-foundation"
readonly sonar_token_path="parent-group-governance/sonarqube/ci-analysis-bot"
readonly sonar_token_field="sonarqube_ci_token"
readonly scanner_image="docker.io/sonarsource/sonar-scanner-cli:12.1.0.3225_8.0.1"

# Exported environment variables SHALL override default workstation analysis endpoints.
readonly sonar_host_url="${SONAR_HOST_URL:-http://127.0.0.1:9000}"

# Static analysis and formatting MUST execute within the target Go module directory.
gofmt -w tools
(cd tools/"${cli_module}" && golangci-lint run -c ../../.gitlab/golangci.yml ./...)

go test -C tools/"${cli_module}" -race -count=1 -coverprofile=coverage.out ./...

# Token resolution MUST isolate proxy environment evaluation to prevent variable leaks and capture execution failures.
if ! command -v vault-proxy-env >/dev/null; then
    echo "vault-proxy-env is missing, run the first menu item of ./governance in parent-group-governance" >&2
    exit 1
fi
proxy_env=$(vault-proxy-env credential-distributor)
sonar_token=$(eval "${proxy_env}" && vault kv get -mount=secret -field="${sonar_token_field}" "${sonar_token_path}")
unset proxy_env

# Container mounts MUST remain read-only and restricted to tracked source trees to prevent analyzer modification.
SONAR_TOKEN="${sonar_token}" podman run --rm --network host \
    --security-opt label=type:spc_t \
    -e SONAR_HOST_URL="${sonar_host_url}" \
    -e SONAR_TOKEN \
    -e SONAR_SCANNER_OPTS="-Dsonar.projectKey=${sonar_project_key} -Dsonar.projectBaseDir=/usr/src -Dsonar.qualitygate.wait=true -Dsonar.sources=tools,terraform,ansible,packer,selinux -Dsonar.exclusions=**/testdata/**,**/.terraform/**,**/*_test.go -Dsonar.tests=tools -Dsonar.test.inclusions=**/*_test.go -Dsonar.go.coverage.reportPaths=tools/${cli_module}/coverage.out" \
    -v "$PWD/tools:/usr/src/tools:ro" \
    -v "$PWD/terraform:/usr/src/terraform:ro" \
    -v "$PWD/ansible:/usr/src/ansible:ro" \
    -v "$PWD/packer:/usr/src/packer:ro" \
    -v "$PWD/selinux:/usr/src/selinux:ro" \
    -v "$PWD/.git:/usr/src/.git:ro" \
    -v "$PWD/.gitignore:/usr/src/.gitignore:ro" \
    "${scanner_image}"

# Binary compilation MUST produce path-independent executables matching deployment images.
# The binary MUST use Go 1.27 or later, since an earlier crypto/x509 rejects the ML-DSA-87 chain of the Vault Proxy.
# The pin applies to this step alone, since golangci-lint built with Go 1.26 refuses a module which pins the toolchain.
readonly build_toolchain="go1.27.2"
for binary in "${cli_binaries[@]}"; do
    GOTOOLCHAIN="${build_toolchain}" CGO_ENABLED=1 go build -C tools/"${cli_module}" -trimpath -ldflags='-s -w' -o ../../"${binary}" ./cmd/"${binary}"
    echo "built: $(pwd)/${binary}"
done
