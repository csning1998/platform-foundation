# External Owner Isolation Verification Runbook

This runbook verifies the security boundaries isolating external owners on the shared Downstream Vault and SPIRE Child clusters. An external owner represents an independent repository or tenant (such as `opgitlab`) whose owner code differs from the platform `project_code`. The primary isolation boundary ensures that an external owner cannot obtain identities, Vault tokens, or certificates belonging to the platform foundation or other tenant owners.

Run this verification suite whenever upgrading Vault, SPIRE, or the `spire-nested` Helm chart, or whenever updating owner policies, owner PKI intermediates, or Kubernetes admission policies.

Sections 2 and 3 run entirely inside ephemeral local containers. Section 4 applies temporary verification resources to the target SPIRE Child cluster and automatically removes the temporary resources upon completion.

---

## Section 1. Scope and Prerequisites

### Item A. Verified Properties

| Property                                                                            | Mechanism                                                                    | Section |
| :---------------------------------------------------------------------------------- | :--------------------------------------------------------------------------- | :------ |
| A JWT-SVID outside the owner prefix cannot log in with the owner role               | `bound_claims_type = "glob"` on the `sub` claim                              | 2       |
| A leaf certificate outside the owner names or owner network is rejected             | Owner PKI intermediate with `permitted_ip_ranges` and `excluded_dns_domains` | 2       |
| A node attests only with a certificate signed by the designated node attestation CA | x509pop `external_pki` with `agent_path_template`                            | 3       |
| An owner registers entries only under its own prefix and designated nodes           | `ClusterStaticEntry` protected by a `ValidatingAdmissionPolicy`              | 4       |

### Item B. Prerequisites

1. Local CLI tools: `podman`, `vault`, `openssl`, `jq`, `kubectl`, and `terraform`.
2. Container images:
    - Section 2 uses `docker.io/hashicorp/vault:2.0` (matching the Bastion Vault version).
    - Section 3 uses `ghcr.io/spiffe/spire-server:1.15.3` and `ghcr.io/spiffe/spire-agent:1.15.3` (matching the `spire-nested` chart `0.30.2`).
3. For Section 4: ensure `vault-proxy-env platform-foundation` is available, the `security-vault-downstream-tenants` layer has been applied, and the `spire-child` operator wrapper is configured on your workstation.

### Item C. Test Data

1. Sections 2 and 3 use mock identifiers: owner `example-owner`, rival owner `example-other`, and trust domain `example.test`.
2. Section 4 dynamically inspects the trust domain and controller-manager class name from the target SPIRE Child cluster, testing against the mock owner `example-owner`.

### Item D. Working Directory Setup

Each step provides an executable bash script. Save each script under `$VERIFY_DIR` with the file name shown in the step title, and run the script via `bash`.

```bash
export VERIFY_DIR=$(mktemp -d)
export PF_ROOT=$(git rev-parse --show-toplevel)
```

---

## Section 2. Vault Login and Issuance Bounds

### Step A. Start the Vault Dev Container (`vault-dev-start.sh`)

Launch a local Vault server in development mode using a non-root, read-only container listening on port 18200.

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "${VERIFY_DIR:?export VERIFY_DIR first}"
umask 077
openssl rand -hex 16 >devtoken
podman run -d --name owner-isolation-vault --cap-drop=ALL --read-only --tmpfs /tmp:rw,mode=1777 \
    --user vault -e HOME=/tmp -e SKIP_SETCAP=1 -p 127.0.0.1:18200:8200 --entrypoint vault \
    docker.io/hashicorp/vault:2.0 server -dev -dev-listen-address=0.0.0.0:8200 \
    -dev-root-token-id="$(cat devtoken)" >/dev/null
sleep 3
VAULT_ADDR=http://127.0.0.1:18200 VAULT_TOKEN=$(cat devtoken) vault status -format=json | jq '{initialized, sealed, version}'
```

Expected output: `initialized` is `true`, `sealed` is `false`, and `version` matches the Bastion Vault version.

### Step B. Verify the Glob JWT Roles (`vault-jwt-glob.sh`)

The operator role binds `spiffe://<td>/<owner>/terraform-operator/*`, while the workload role binds `spiffe://<td>/<owner>/*`. Because `bound_subject` requires an exact string match, wildcard prefixes only take effect when configured via `bound_claims` with `bound_claims_type = "glob"`. This test verifies that JWT-SVIDs outside the expected owner prefix fail authentication.

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "${VERIFY_DIR:?run the Vault dev container step first}"
export VAULT_ADDR=http://127.0.0.1:18200
VAULT_TOKEN=$(cat devtoken)
export VAULT_TOKEN
TD=example.test
ISS=https://issuer.example.test
AUD=example-vault

[ -f jwt.key ] || openssl genrsa -out jwt.key 2048 2>/dev/null
openssl rsa -in jwt.key -pubout -out jwt.pub 2>/dev/null
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
sign_jwt() {
    local sub=$1 now header payload sig
    now=$(date +%s)
    header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
    payload=$(printf '{"iss":"%s","sub":"%s","aud":["%s"],"iat":%d,"exp":%d}' "$ISS" "$sub" "$AUD" "$now" "$((now + 300))" | b64url)
    sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign jwt.key -binary | b64url)
    printf '%s.%s.%s' "$header" "$payload" "$sig"
}

vault auth enable -path=verify-jwt jwt >/dev/null 2>&1 || true
vault write auth/verify-jwt/config jwt_validation_pubkeys=@jwt.pub bound_issuer="$ISS" >/dev/null
for role in operator workload; do
    prefix="spiffe://$TD/example-owner/terraform-operator/*"
    [ "$role" = workload ] && prefix="spiffe://$TD/example-owner/*"
    vault write "auth/verify-jwt/role/$role" - >/dev/null <<EOF
{ "role_type": "jwt", "user_claim": "sub", "bound_audiences": ["$AUD"], "bound_claims_type": "glob",
  "bound_claims": { "sub": "$prefix" }, "token_policies": ["default"], "token_ttl": "5m" }
EOF
done

try() {
    local role=$1 sub=$2 expect=$3 result
    if vault write -format=json auth/verify-jwt/login role="$role" jwt=- <<<"$(sign_jwt "$sub")" >/dev/null 2>err.txt; then
        result=allow
    else
        result=deny
    fi
    printf '%-8s %-6s expect=%-6s %s  %s\n' "$role" "$result" "$expect" "$([ "$result" = "$expect" ] && echo OK || echo MISMATCH)" "$sub"
}

try operator "spiffe://$TD/example-owner/terraform-operator/gitlab/postgres" allow
try operator "spiffe://$TD/example-owner/terraform-operator/registration" allow
try operator "spiffe://$TD/example-owner/terraform-operator" deny
try operator "spiffe://$TD/example-owner/gitlab/postgres" deny
try operator "spiffe://$TD/example-other/terraform-operator/gitlab/postgres" deny
try operator "spiffe://$TD/example-owner-x/terraform-operator/gitlab/postgres" deny
try operator "spiffe://other.test/example-owner/terraform-operator/gitlab/postgres" deny
try workload "spiffe://$TD/example-owner/gitlab/postgres" allow
try workload "spiffe://$TD/example-owner-x/gitlab/postgres" deny
try workload "spiffe://$TD/example-other/gitlab/postgres" deny
try workload "spiffe://$TD/platform/terraform-operator/keycloak/frontend" deny
```

Expected output: Every test line prints `OK`. Denied logins fail with `claim "sub" does not match any associated bound claim values`.

### Step C. Verify the Owner PKI Intermediate (`vault-pki-owner.sh`)

Because a wildcard `*` in Vault PKI role domains can cross dot separators (e.g. `<owner>-*.<stage>.<suffix>` inadvertently matching `<owner>-a.<platform service>.<stage>.<suffix>`), the intermediate CA enforces X.509 Name Constraints that explicitly block platform service domains and restrict allowed IP SAN ranges. Vault enforces these Name Constraints at certificate issuance time, and the TLS verifier enforces the same Name Constraints again during chain verification.

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "${VERIFY_DIR:?run the Vault dev container step first}"
export VAULT_ADDR=http://127.0.0.1:18200
VAULT_TOKEN=$(cat devtoken)
export VAULT_TOKEN
SUFFIX=production.example.test

vault secrets enable -path=verify-root pki >/dev/null 2>&1 || true
vault secrets tune -max-lease-ttl=87600h verify-root >/dev/null
vault write -field=certificate verify-root/root/generate/internal common_name="Verify Root" \
    key_type=ec key_bits=256 ttl=87600h >root.pem 2>/dev/null
vault secrets enable -path=verify-owner pki >/dev/null 2>&1 || true
vault secrets tune -max-lease-ttl=8760h verify-owner >/dev/null
vault write -field=csr verify-owner/intermediate/generate/internal common_name="Verify Owner Intermediate" \
    key_type=ec key_bits=256 >owner.csr
vault write -field=certificate verify-root/root/sign-intermediate csr=@owner.csr format=pem ttl=8760h \
    permitted_ip_ranges="172.16.140.0/24" \
    excluded_dns_domains="keycloak.$SUFFIX,.keycloak.$SUFFIX" >owner.pem 2>/dev/null
vault write verify-owner/intermediate/set-signed certificate=@owner.pem >/dev/null
openssl x509 -in owner.pem -noout -ext nameConstraints
vault write verify-owner/roles/example-owner allowed_domains="example-owner-*.$SUFFIX,gitlab.$SUFFIX" \
    allow_glob_domains=true allow_subdomains=true allow_bare_domains=true allow_ip_sans=true \
    key_type=ec key_bits=256 ttl=1h >/dev/null

issue() {
    local expect=$1 result
    shift
    if vault write -format=json verify-owner/issue/example-owner "$@" >leaf.json 2>err.txt; then result=allow; else result=deny; fi
    printf '%-6s expect=%-6s %s  %s\n' "$result" "$expect" "$([ "$result" = "$expect" ] && echo OK || echo MISMATCH)" "$*"
}

issue allow common_name="example-owner-gitlab-postgres.$SUFFIX"
issue allow common_name="gitlab.$SUFFIX"
issue allow common_name="registry.gitlab.$SUFFIX"
issue deny common_name="example-owner-a.keycloak.$SUFFIX"
issue deny common_name="keycloak.$SUFFIX"
issue deny common_name="example-other-gitlab-postgres.$SUFFIX"
issue deny common_name="x.example-owner-gitlab-postgres.$SUFFIX"
issue deny common_name="example-owner-a.$SUFFIX.evil.test"
issue deny common_name="gitlab.$SUFFIX.evil.test"
issue allow common_name="example-owner-gitlab-postgres.$SUFFIX" ip_sans=172.16.140.21
issue deny common_name="example-owner-gitlab-postgres.$SUFFIX" ip_sans=172.16.126.251

# A leaf which Vault issues still passes the chain check, which the verifier repeats against the Name Constraints.
vault write -format=json verify-owner/issue/example-owner common_name="example-owner-gitlab-postgres.$SUFFIX" \
    ip_sans=172.16.140.21 | jq -r .data.certificate >leaf.pem
openssl verify -CAfile root.pem -untrusted owner.pem leaf.pem
```

Expected output:

1. The Name Constraints output lists the permitted owner network (`172.16.140.0/24`) and the excluded platform domains (`keycloak.$SUFFIX` and `.keycloak.$SUFFIX`).
2. Every `issue` line outputs `OK`. Unauthorized domain names or IP addresses are denied with `not authorized to sign for this name`.
3. `openssl verify` outputs `leaf.pem: OK`.

### Step D. Remove the Vault Dev Container

```bash
podman rm -f owner-isolation-vault
```

---

## Section 3. Node Attestation with x509pop

### Step A. Verify the Agent Path and Trust Anchor Enforcement (`spire-x509pop.sh`)

This script starts an isolated SPIRE server configured with the `x509pop` node attestor in `external_pki` mode, pointing to a dedicated node attestation CA. The script spins up two agents: one holding a valid node certificate signed by the node CA, and a rogue agent holding a certificate signed by an untrusted CA.

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "${VERIFY_DIR:?export VERIFY_DIR first}"
umask 077
mkdir -p x509pop/server x509pop/agent x509pop/rogue
cd x509pop

new_ca() {
    openssl ecparam -name prime256v1 -genkey -noout -out "$1.key"
    openssl req -x509 -new -key "$1.key" -subj "/CN=$2" -days 1 -out "$1.crt" \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
}
new_leaf() {
    openssl ecparam -name prime256v1 -genkey -noout -out "$3/node.key"
    openssl req -new -key "$3/node.key" -subj "/CN=$2" -out "$3/node.csr"
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n' >leaf.ext
    openssl x509 -req -in "$3/node.csr" -CA "$1.crt" -CAkey "$1.key" -CAcreateserial -days 1 -extfile leaf.ext \
        -out "$3/node.crt" 2>/dev/null
}

new_ca node-ca "Verify Node Attestation CA"
new_ca rogue-ca "Rogue CA"
cp node-ca.crt server/node-ca.crt
new_leaf node-ca example-owner-gitlab-postgres-1 agent
new_leaf rogue-ca platform-keycloak-frontend-1 rogue

cat >server/server.conf <<'EOF'
server {
  bind_address = "0.0.0.0"
  bind_port = "8081"
  trust_domain = "example.test"
  data_dir = "/tmp/data"
}
plugins {
  DataStore "sql" {
    plugin_data {
      database_type = "sqlite3"
      connection_string = "/tmp/data/datastore.sqlite3"
    }
  }
  KeyManager "memory" {
    plugin_data {}
  }
  NodeAttestor "x509pop" {
    plugin_data {
      mode = "external_pki"
      ca_bundle_path = "/conf/node-ca.crt"
      agent_path_template = "/{{ .PluginName }}/{{ .Subject.CommonName }}"
    }
  }
}
EOF
for dir in agent rogue; do
  cat >"$dir/agent.conf" <<'EOF'
agent {
  data_dir = "/tmp/data"
  server_address = "owner-isolation-spire-server"
  server_port = "8081"
  socket_path = "/tmp/agent/api.sock"
  trust_domain = "example.test"
  insecure_bootstrap = true
}
plugins {
  KeyManager "memory" {
    plugin_data {}
  }
  NodeAttestor "x509pop" {
    plugin_data {
      private_key_path = "/conf/node.key"
      certificate_path = "/conf/node.crt"
    }
  }
  WorkloadAttestor "unix" {
    plugin_data {}
  }
}
EOF
done
chmod 755 server agent rogue
chmod 644 server/* agent/* rogue/*

podman network create owner-isolation >/dev/null 2>&1 || true
run() {
  podman run -d --name "owner-isolation-$1" --network owner-isolation --cap-drop=ALL --read-only \
    --tmpfs /tmp:rw,mode=1777 -v "$PWD/$2:/conf:ro,Z" "ghcr.io/spiffe/$3:1.15.3" -config "/conf/$4" >/dev/null
}
run spire-server server spire-server server.conf
sleep 4
run spire-agent agent spire-agent agent.conf
run spire-rogue rogue spire-agent agent.conf
sleep 10

podman exec owner-isolation-spire-server /opt/spire/bin/spire-server agent list | grep -E 'SPIFFE ID|Attestation type'
podman logs owner-isolation-spire-rogue 2>&1 | grep -o 'PermissionDenied desc = [^"]*' | head -1
```

Expected output:

1. The attested agent list shows only the legitimate agent: `spiffe://example.test/spire/agent/x509pop/example-owner-gitlab-postgres-1` with attestation type `x509pop`.
2. The rogue agent fails node attestation with `certificate signed by unknown authority`.
3. Note on configuration: `agent_path_template` requires a leading slash (`/`). SPIRE 1.15.3 rejects templates without a leading slash with `path must have a leading slash`.

### Step B. Remove the SPIRE Containers

```bash
podman rm -f owner-isolation-spire-server owner-isolation-spire-agent owner-isolation-spire-rogue
podman network rm owner-isolation
```

---

## Section 4. Registration Bounds on the SPIRE Child

### Step A. Save the Admission Script (`spire-child-admission.sh`)

This script creates an ephemeral ServiceAccount restricted to managing `clusterstaticentries`, creates a `ValidatingAdmissionPolicy` whose match condition selects the requests of that ServiceAccount, and runs positive and negative registration test cases. All resources use the `owner-isolation-verify` name/label and are automatically removed by a cleanup trap on exit.

The admission policy uses anchored RE2 regular expressions rather than simple prefix matching (`startsWith`) to prevent path traversal attacks (such as injecting `..` segments).

```bash
#!/usr/bin/env bash
# An admission policy bounds the ClusterStaticEntry of one ServiceAccount to its owner prefix.
# Run as KUBECONFIG=<Child admin kubeconfig> bash spire-child-admission.sh, which deletes every verify resource on exit.
set -euo pipefail
: "${KUBECONFIG:?KUBECONFIG MUST point to the Child admin kubeconfig}"
[ -s "$KUBECONFIG" ] || { echo "KUBECONFIG ${KUBECONFIG} is empty or missing"; exit 1; }
kubectl version --request-timeout=10s >/dev/null || { echo "the Child API server is unreachable"; exit 1; }

NS_SERVER=spire-server
POD=spire-internal-server-0
CONTAINER=internal-spire-server
SA_NS=owner-isolation-verify
SA=example-owner-registrar
AS="system:serviceaccount:${SA_NS}:${SA}"

TD=$(kubectl -n "$NS_SERVER" get cm spire-internal-server -o json |
  jq -r '.data["server.conf"] | capture("trust_domain\"?\\s*[:=]\\s*\"(?<td>[^\"]+)\"").td')
CLASS=$(kubectl -n "$NS_SERVER" get cm spire-internal-controller-manager -o json |
  jq -r '.data["controller-manager-config.yaml"] | capture("className:\\s*\"?(?<c>[^\"\\n]+)\"?").c')
echo "trust_domain=${TD} className=${CLASS}"
[ -n "$TD" ] && [ "$TD" != null ] && [ -n "$CLASS" ] && [ "$CLASS" != null ] || { echo "trust domain or className not found"; exit 1; }

WORKSTATION="spiffe://${TD}/spire/agent/join_token/owner-isolation-verify-workstation"
TD_RE=${TD//./\\.}

cleanup() {
  kubectl delete clusterstaticentries.spire.spiffe.io -l owner-isolation-verify=true --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete validatingadmissionpolicybinding owner-isolation-verify-owner-entries --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete validatingadmissionpolicy owner-isolation-verify-owner-entries --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete clusterrolebinding owner-isolation-verify-clusterstaticentries --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete clusterrole owner-isolation-verify-clusterstaticentries --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete namespace "$SA_NS" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata: { name: ${SA_NS} }
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: ${SA}, namespace: ${SA_NS} }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: owner-isolation-verify-clusterstaticentries }
rules:
  - apiGroups: ["spire.spiffe.io"]
    resources: ["clusterstaticentries"]
    verbs: ["create", "get", "list", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: owner-isolation-verify-clusterstaticentries }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: owner-isolation-verify-clusterstaticentries }
subjects:
  - { kind: ServiceAccount, name: ${SA}, namespace: ${SA_NS} }
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: { name: owner-isolation-verify-owner-entries }
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: ["spire.spiffe.io"]
        apiVersions: ["*"]
        operations: ["CREATE", "UPDATE"]
        resources: ["clusterstaticentries"]
  matchConditions:
    - name: owner-registrar
      expression: 'request.userInfo.username == "${AS}"'
  validations:
    - expression: 'object.spec.spiffeID.matches(r"^spiffe://${TD_RE}/example-owner(/[a-z0-9_-][a-z0-9._-]*)+$")'
      message: spiffeID MUST stay below the owner prefix
    - expression: >-
        object.spec.parentID == "${WORKSTATION}" ||
        object.spec.parentID.matches(r"^spiffe://${TD_RE}/spire/agent/x509pop/example-owner-[a-z0-9-]+$")
      message: parentID MUST be the workstation agent or an owner node
    - expression: '!has(object.spec.admin) || object.spec.admin == false'
      message: admin MUST be false
    - expression: '!has(object.spec.downstream) || object.spec.downstream == false'
      message: downstream MUST be false
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata: { name: owner-isolation-verify-owner-entries }
spec:
  policyName: owner-isolation-verify-owner-entries
  validationActions: ["Deny"]
EOF
sleep 5

entry() {
  local name=$1 spiffe=$2 parent=$3 extra=${4:-}
  cat <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterStaticEntry
metadata: { name: ${name}, labels: { owner-isolation-verify: "true" } }
spec:
  className: ${CLASS}
  spiffeID: ${spiffe}
  parentID: ${parent}
  selectors: ["unix:uid:65534"]
${extra}
EOF
}

try() {
  local label=$1 expect=$2 result
  shift 2
  if "$@" >/dev/null 2>err.txt; then result=allow; else result=deny; fi
  printf '%-34s %-6s expect=%-6s %s  %s\n' "$label" "$result" "$expect" \
    "$([ "$result" = "$expect" ] && echo OK || echo MISMATCH)" "$(grep -o 'message: [^.]*\|denied[^:]*' err.txt | head -1)"
}

create_as() { entry "$@" | kubectl create --as="$AS" -f -; }

try "allowed entry"                allow create_as owner-isolation-verify-allowed "spiffe://${TD}/example-owner/spike/allowed" "spiffe://${TD}/spire/agent/x509pop/example-owner-node-1"
try "workstation parent"           allow create_as owner-isolation-verify-workstation "spiffe://${TD}/example-owner/terraform-operator/spike" "$WORKSTATION"
try "platform spiffeID"            deny  create_as owner-isolation-verify-platform "spiffe://${TD}/platform-foundation/terraform-operator/keycloak/frontend" "$WORKSTATION"
try "owner prefix collision"       deny  create_as owner-isolation-verify-collision "spiffe://${TD}/example-owner-x/spike" "$WORKSTATION"
try "path-form spiffeID"           deny  create_as owner-isolation-verify-pathform "/example-owner/spike/pathform" "$WORKSTATION"
try "dot-dot spiffeID"             deny  create_as owner-isolation-verify-dotdot "spiffe://${TD}/example-owner/../platform-foundation/x" "$WORKSTATION"
try "platform node parent"         deny  create_as owner-isolation-verify-parent "spiffe://${TD}/example-owner/spike/p" "spiffe://${TD}/spire/agent/x509pop/platform-foundation-harbor-origin-frontend-1"
try "admin true"                   deny  create_as owner-isolation-verify-admin "spiffe://${TD}/example-owner/spike/a" "$WORKSTATION" "  admin: true"
try "downstream true"              deny  create_as owner-isolation-verify-downstream "spiffe://${TD}/example-owner/spike/d" "$WORKSTATION" "  downstream: true"
try "update to platform spiffeID"  deny  kubectl patch --as="$AS" clusterstaticentries.spire.spiffe.io owner-isolation-verify-allowed --type=merge \
  -p "{\"spec\":{\"spiffeID\":\"spiffe://${TD}/platform-foundation/terraform-operator/keycloak/frontend\"}}"
try "create ClusterSPIFFEID (RBAC)" deny kubectl auth can-i create clusterspiffeids.spire.spiffe.io --as="$AS" --quiet

sleep 20
echo "--- controller-manager status of the allowed entries"
kubectl get clusterstaticentries.spire.spiffe.io -l owner-isolation-verify=true \
  -o custom-columns=NAME:.metadata.name,RENDERED:.status.rendered,MASKED:.status.masked,SET:.status.set
echo "--- spire-server entry show"
kubectl -n "$NS_SERVER" exec "$POD" -c "$CONTAINER" -- /opt/spire/bin/spire-server entry show \
  -socketPath /tmp/spire-server/private/api.sock -spiffeID "spiffe://${TD}/example-owner/spike/allowed" |
  grep -E 'SPIFFE ID|Parent ID|Selector|Entry ID'
```

### Step B. Save the Runner (`spire-child-run.sh`)

This runner authenticates to the Downstream Vault as the `spire-child` operator, fetches the Child cluster admin kubeconfig from the Vault KV store, and runs `spire-child-admission.sh`.

```bash
#!/usr/bin/env bash
# Logs in as the spire-child operator, fetches the Child admin kubeconfig, and runs spire-child-admission.sh.
# CHECK_ONLY=1 stops after the read-only checks. The kubeconfig and the Vault token are removed on exit.
set -euo pipefail
umask 077
cd "${VERIFY_DIR:?export VERIFY_DIR first}"
PF_ROOT=${PF_ROOT:?export PF_ROOT as the platform-foundation checkout}
TENANTS="${PF_ROOT}/terraform/layers/security-vault-downstream-tenants"
KUBECONFIG_FILE="${VERIFY_DIR}/child.kubeconfig"

cleanup() {
  rm -f "$KUBECONFIG_FILE"
  if [ -n "${VAULT_TOKEN:-}" ]; then vault token revoke -self >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

proxy_env=$(vault-proxy-env platform-foundation)
eval "${proxy_env}"
unset proxy_env
endpoint=$(terraform -chdir="$TENANTS" output -raw downstream_vault_endpoint)
ca_cert=$(terraform -chdir="$TENANTS" output -raw downstream_vault_ca_cert_path)
operator=$(terraform -chdir="$TENANTS" output -json downstream_vault_operators | jq -c '.spire.child')
kv_path=$(terraform -chdir="$TENANTS" output -json foundation_vault_path | jq -r '.kv_paths.spire.child.cluster_config')
unset VAULT_TOKEN VAULT_CLIENT_CERT VAULT_CLIENT_KEY VAULT_AGENT_ADDR

export VAULT_ADDR="$endpoint" VAULT_CACERT="$ca_cert"
jwt=$("/usr/local/bin/$(jq -r .wrapper_name <<<"$operator")" | jq -r .jwt)
VAULT_TOKEN=$(vault write -field=token "auth/$(jq -r .auth_mount <<<"$operator")/login" \
  role="$(jq -r .role_name <<<"$operator")" jwt=- <<<"$jwt")
export VAULT_TOKEN
unset jwt

vault kv get -mount=secret -field=content_b64 "$kv_path" | base64 -d >"$KUBECONFIG_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"
kubectl version --request-timeout=10s -o json | jq -r '"server " + .serverVersion.gitVersion'
kubectl get crd clusterstaticentries.spire.spiffe.io -o jsonpath='{.spec.versions[*].name}{"\n"}'
[ "${CHECK_ONLY:-0}" = 1 ] && exit 0
bash "${VERIFY_DIR}/spire-child-admission.sh"
```

### Step C. Run the Read-only Check

Run a preliminary check to confirm cluster connectivity and verify that the `ClusterStaticEntry` CRD is installed:

```bash
CHECK_ONLY=1 bash "${VERIFY_DIR}/spire-child-run.sh"
```

Expected output: Prints the Kubernetes API server version and reports `v1alpha1` for the `ClusterStaticEntry` CRD. No resources are created.

### Step D. Run the Admission Verification

Execute the full verification script:

```bash
bash "${VERIFY_DIR}/spire-child-run.sh"
```

Expected output:

1. The first line prints the detected trust domain and controller-manager class name.
2. Every test case outputs `OK`. The two authorized entries are admitted, while the remaining nine cases are denied.
3. `spire-server entry show` lists the allowed entry with an entry ID prefixed by the SPIRE Child cluster name.
4. Note on controller status: `status.set` on a `ClusterStaticEntry` may remain `false` even after the entry is active. Always confirm the registration state directly via `spire-server entry show`.

### Step E. Remove the Work Directory

```bash
rm -rf "${VERIFY_DIR}"
```

---

## Section 5. Recorded Results

| Date       | Vault   | SPIRE    | `spire-nested` | Kubernetes | Result                                                                                                                                                        |
| :--------- | :------ | :------- | :------------- | :--------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 2026-10-14 | `2.0.4` | `1.15.3` | `0.30.2`       | `v1.36.5`  | All isolation properties verified successfully. Because Vault PKI glob matching crosses dots (`.`), the intermediate CA explicitly excludes platform domains. |
