# External Owner Isolation Verification Runbook

This runbook verifies the security boundaries isolating external owners on the shared Downstream Vault and SPIRE Child clusters. An external owner represents an independent repository or tenant (such as `opgitlab`) whose owner code differs from the platform `project_code`. The primary isolation boundary ensures that an external owner cannot obtain identities, Vault tokens, or certificates belonging to the platform foundation or other tenant owners.

Run this verification suite whenever upgrading Vault, SPIRE, or the `spire-nested` Helm chart, or whenever updating owner policies, owner PKI intermediates, or Kubernetes admission policies.

Sections 2 and 3 run entirely inside ephemeral local containers. Section 4 runs against the live SPIRE Child and the Downstream Vault after `provision-spire-child` has been applied. Every request of the owner caller in Section 4 is a server-side dry run, and the one fixture entry of the script is removed on exit.

---

## Section 1. Scope and Prerequisites

### Item A. Verified Properties

| Property                                                                            | Mechanism                                                                    | Section |
| :---------------------------------------------------------------------------------- | :--------------------------------------------------------------------------- | :------ |
| A JWT-SVID outside the owner prefix cannot log in with the owner role               | `bound_claims_type = "glob"` on the `sub` claim                              | 2       |
| A leaf certificate outside the owner names or owner network is rejected             | Owner PKI intermediate with `permitted_ip_ranges` and `excluded_dns_domains` | 2       |
| A workload receives an owner identity only on a node with an owner certificate      | x509pop `external_pki` and a node alias selecting the subject CN             | 3       |
| An owner registers entries only under its own prefix and designated nodes           | `ClusterStaticEntry` protected by a `ValidatingAdmissionPolicy`              | 4       |
| A platform JWT-SVID cannot log in with an owner role on the live Child mount        | Owner glob roles and their rate limit quotas                                 | 4       |

### Item B. Prerequisites

1. Local CLI tools: `podman`, `vault`, `openssl`, `jq`, `kubectl`, and `terraform`.
2. Container images:
    - Section 2 uses `docker.io/hashicorp/vault:2.0` (matching the Bastion Vault version).
    - Section 3 uses `ghcr.io/spiffe/spire-server:1.15.3` and `ghcr.io/spiffe/spire-agent:1.15.3` (matching the `spire-nested` chart `0.30.2`).
3. For Section 4: ensure `vault-proxy-env platform-foundation` is available, `security-vault-downstream-tenants`, `platform-spire-child`, and `provision-spire-child` have been applied, and the `spire-child` and `keycloak` operator wrappers are configured on your workstation. The script calls `sudo` once to fetch a JWT-SVID as the `keycloak` service user.

### Item C. Test Data

1. Sections 2 and 3 use mock identifiers: owner `example-owner`, rival owner `example-other`, and trust domain `example.test`.
2. Section 4 reads the trust domain from the owner coordinates of `security-vault-downstream-tenants` and the class name from the controller-manager. The `keycloak` operator acts as the owner `platform-foundation`, and `opgitlab` acts as the other owner.

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

### Step A. Verify the Node Alias across Certificate Rotation (`spire-x509pop.sh`)

This script starts an isolated SPIRE server with the `x509pop` node attestor in `external_pki` mode and without `agent_path_template`, matching the server rendered by `spire-nested`. The server registers a node alias selecting the subject CN of an owner node and a workload entry below the alias. Two agents present certificates from the same node CA: one carries the owner CN, and the other carries a platform CN. The script then rotates the owner certificate and restarts the owner agent with an empty data directory.

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "${VERIFY_DIR:?export VERIFY_DIR first}"
umask 077
mkdir -p x509pop/server x509pop/agent x509pop/other
cd x509pop

new_ca() {
    openssl ecparam -name prime256v1 -genkey -noout -out "$1.key"
    openssl req -x509 -new -key "$1.key" -subj "/CN=$2" -days 1 -out "$1.crt" \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
}
new_leaf() {
    openssl ecparam -name prime256v1 -genkey -noout -out "$2/node.key"
    openssl req -new -key "$2/node.key" -subj "/CN=$1" -out "$2/node.csr"
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n' >leaf.ext
    openssl x509 -req -in "$2/node.csr" -CA node-ca.crt -CAkey node-ca.key -CAcreateserial -days 1 -extfile leaf.ext \
        -out "$2/node.crt" 2>/dev/null
    chmod 644 "$2"/*
}

new_ca node-ca "Verify Node Attestation CA"
cp node-ca.crt server/node-ca.crt
new_leaf example-owner-node-1.example.test agent
new_leaf platform-foundation-node-1.example.test other

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
    }
  }
}
EOF
for dir in agent other; do
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
chmod 755 server agent other
chmod 644 server/* agent/* other/*

podman network create owner-isolation >/dev/null 2>&1 || true
run() {
  podman run -d --name "owner-isolation-$1" --network owner-isolation --cap-drop=ALL --read-only \
    --tmpfs /tmp:rw,mode=1777 -v "$PWD/$2:/conf:ro,Z" "ghcr.io/spiffe/$3:1.15.3" -config "/conf/$4" >/dev/null
}
srv() { podman exec owner-isolation-spire-server /opt/spire/bin/spire-server "$@"; }
fetch() {
  podman exec "owner-isolation-spire-$1" /opt/spire/bin/spire-agent api fetch x509 -socketPath /tmp/agent/api.sock -timeout 5s 2>&1 |
    grep -E 'SPIFFE ID|no identity' | head -1 || true
}

run spire-server server spire-server server.conf
sleep 4
srv entry create -node -spiffeID spiffe://example.test/example-owner/node/node-1 \
  -selector x509pop:subject:cn:example-owner-node-1.example.test >/dev/null
srv entry create -parentID spiffe://example.test/example-owner/node/node-1 \
  -spiffeID spiffe://example.test/example-owner/app -selector unix:uid:0 >/dev/null
run spire-agent agent spire-agent agent.conf
run spire-other other spire-agent agent.conf
sleep 12

echo "--- agents before rotation"
srv agent list | grep 'SPIFFE ID'
echo "--- owner node: $(fetch agent)"
echo "--- platform node: $(fetch other)"

new_leaf example-owner-node-1.example.test agent
podman restart owner-isolation-spire-agent >/dev/null
sleep 12
echo "--- agents after rotation"
srv agent list | grep 'SPIFFE ID'
echo "--- owner node after rotation: $(fetch agent)"
```

Expected output:

1. Both agents attest as `spiffe://example.test/spire/agent/x509pop/<certificate fingerprint>`. `spire-nested` renders no `agent_path_template` in `externalPKI` mode, and the agent ID therefore carries the fingerprint instead of the CN.
2. The owner node receives `spiffe://example.test/example-owner/app`. The platform node, whose certificate comes from the same CA, reports `no identity issued`.
3. After rotation, the agent list shows a third agent ID with a new fingerprint, and the owner node still receives `spiffe://example.test/example-owner/app` through the node alias. The agent of the old certificate stays listed until its SVID expires.

### Step B. Remove the SPIRE Containers

```bash
podman rm -f owner-isolation-spire-server owner-isolation-spire-agent owner-isolation-spire-other
podman network rm owner-isolation
```

---

## Section 4. Registration Bounds on the SPIRE Child

### Step A. Save the Registration Script (`spire-child-registration.sh`)

This script logs in as the `spire-child` operator to read the Child admin kubeconfig and the owner coordinates. The admin creates one fixture entry of the platform, and then impersonates an operator of the owner `opgitlab` with the group `spire-owner-operator:opgitlab`, which kube-apiserver assigns to the JWT-SVID of such an operator. Every registration case runs as a server-side dry run. The `keycloak` operator fetches a JWT-SVID with the Kubernetes audience to confirm that the platform group holds no registration grant, and logs in to the Child mount with its Vault audience JWT-SVID.

```bash
#!/usr/bin/env bash
# The admin impersonates an operator of opgitlab, and every caller request is a server-side dry run.
# The fixture entry of the platform and the Vault token are removed on exit.
set -euo pipefail
umask 077
cd "${VERIFY_DIR:?export VERIFY_DIR first}"
LAYERS="${PF_ROOT:?export PF_ROOT as the platform-foundation checkout}/terraform/layers"
FIXTURE=owner-isolation-verify-foreign
cleanup() {
  [ -s admin.kubeconfig ] && KUBECONFIG=admin.kubeconfig kubectl delete clusterstaticentries.spire.spiffe.io "$FIXTURE" --ignore-not-found >/dev/null 2>&1 || true
  rm -f admin.kubeconfig platform.kubeconfig err.txt
  if [ -n "${VAULT_TOKEN:-}" ]; then vault token revoke -self >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

proxy_env=$(vault-proxy-env platform-foundation)
eval "${proxy_env}"
unset proxy_env
tenants() { terraform -chdir="$LAYERS/security-vault-downstream-tenants" output "$@"; }
endpoints=$(terraform -chdir="$LAYERS/platform-spire-child" output -json spire_child_endpoints)
operator=$(tenants -json downstream_vault_operators | jq -c '.spire.child')
owners=$(tenants -json downstream_vault_owners)
kv_path=$(tenants -json foundation_vault_path | jq -r '.kv_paths.spire.child.cluster_config')
unset VAULT_TOKEN VAULT_CLIENT_CERT VAULT_CLIENT_KEY VAULT_AGENT_ADDR
export VAULT_ADDR=$(tenants -raw downstream_vault_endpoint) VAULT_CACERT=$(tenants -raw downstream_vault_ca_cert_path)
jwt=$("/usr/local/bin/$(jq -r .wrapper_name <<<"$operator")" | jq -r .jwt)
VAULT_TOKEN=$(vault write -field=token "auth/$(jq -r .auth_mount <<<"$operator")/login" role="$(jq -r .role_name <<<"$operator")" jwt=- <<<"$jwt")
export VAULT_TOKEN
unset jwt
vault kv get -mount=secret -field=content_b64 "$kv_path" | base64 -d >admin.kubeconfig
admin() { KUBECONFIG=admin.kubeconfig kubectl "$@"; }

TD=$(jq -r '.opgitlab.operator.spiffe_prefix' <<<"$owners" | sed -E 's#^spiffe://([^/]+)/.*#\1#')
CLASS=$(admin -n spire-server get cm spire-internal-controller-manager -o json |
  jq -r '.data["controller-manager-config.yaml"] | capture("className:\\s*\"?(?<c>[^\"\\n]+)\"?").c')
WORKSTATION=$(admin -n spire-server get cm spire-owner-registration -o jsonpath='{.data.workstation_agent_id}')

echo "--- server attestors and registration objects"
admin -n spire-server get cm spire-internal-server -o json | jq -r '.data["server.conf"] | fromjson | .plugins.NodeAttestor | map(keys[0]) | join(" ")'
admin get validatingadmissionpolicy,validatingadmissionpolicybinding spire-owner-registration --no-headers | awk '{print $1}'
admin -n spire-server exec spire-internal-server-0 -c internal-spire-server -- /opt/spire/bin/spire-server agent list \
  -socketPath /tmp/spire-server/private/api.sock | grep -qF "$WORKSTATION" &&
  echo "workstation parameter matches an attested agent" || echo "workstation parameter MISMATCH"

admin apply -f - >/dev/null <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterStaticEntry
metadata: { name: ${FIXTURE} }
spec:
  className: ${CLASS}
  spiffeID: spiffe://${TD}/platform-foundation/verify/foreign
  parentID: spiffe://${TD}/spire/server
  selectors: ["x509pop:subject:cn:platform-foundation-verify-none.${TD}"]
EOF

k8s_jwt=$(sudo -u svc-platform-foundation-terraform-operator-keycloak-frontend /usr/local/bin/spire-agent api fetch jwt \
  -audience "$(jq -r .kubernetes_jwt_audience <<<"$endpoints")" -socketPath /run/spire-agent-child/public/api.sock -output json |
  jq -r 'try .[0].svids[0].svid catch empty')
admin config view --raw --minify -o json |
  jq --arg token "$k8s_jwt" '.users = [{name: "jwt", user: {token: $token}}] | .contexts[0].context.user = "jwt"' >platform.kubeconfig
unset k8s_jwt
platform() { KUBECONFIG=platform.kubeconfig kubectl "$@"; }
echo "platform operator: $(platform auth whoami -o json | jq -c '.status.userInfo | {username, groups}')"
caller() {
  admin --as="spiffe://${TD}/opgitlab/terraform-operator/verify" \
    --as-group=spire-owner-operator:opgitlab --as-group=system:authenticated "$@"
}
echo "owner caller: $(caller auth whoami -o json | jq -c '.status.userInfo | {username, groups}')"

entry() {
  cat <<EOF
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterStaticEntry
metadata: { name: owner-isolation-verify-$RANDOM }
spec:
  className: ${CLASS}
  spiffeID: $1
  parentID: $2
  selectors: $3
${4:-}
EOF
}
try() {
  local label=$1 expect=$2 result
  shift 2
  if "$@" >/dev/null 2>err.txt; then result=allow; else result=deny; fi
  printf '%-44s %-6s expect=%-6s %s  %s\n' "$label" "$result" "$expect" \
    "$([ "$result" = "$expect" ] && echo OK || echo MISMATCH)" "$(grep -o 'denied request: [^.]*' err.txt | head -1)"
}
create() { entry "$@" | caller create --dry-run=server -f -; }

OWN="spiffe://${TD}/opgitlab/verify"
ALIAS="${OWN}/node/n1"
SERVER="spiffe://${TD}/spire/server"
UID_SEL='["unix:uid:65534"]'

echo "--- registration bounds"
try "node alias with owner CN"          allow create "$ALIAS" "$SERVER" "[\"x509pop:subject:cn:opgitlab-verify-n1.${TD}\"]"
try "workload below owner alias"        allow create "${OWN}/app" "$ALIAS" "$UID_SEL"
try "workstation parent"                allow create "${OWN}/operator" "$WORKSTATION" "$UID_SEL"
try "spiffeID of another owner"         deny  create "spiffe://${TD}/platform-foundation/verify/app" "$WORKSTATION" "$UID_SEL"
try "owner prefix collision"            deny  create "spiffe://${TD}/opgitlab-x/app" "$WORKSTATION" "$UID_SEL"
try "dot-dot spiffeID"                  deny  create "${OWN}/../../platform-foundation/app" "$WORKSTATION" "$UID_SEL"
try "other join_token parent"           deny  create "${OWN}/app" "spiffe://${TD}/spire/agent/join_token/00000000-0000-0000-0000-000000000000" "$UID_SEL"
try "alias with another owner CN"       deny  create "${OWN}/node/n2" "$SERVER" "[\"x509pop:subject:cn:platform-foundation-n2.${TD}\"]"
try "alias with a non-CN selector"      deny  create "${OWN}/node/n3" "$SERVER" "[\"x509pop:subject:cn:opgitlab-n3.${TD}\", \"k8s_psat:cluster:x\"]"
try "admin true"                        deny  create "${OWN}/a" "$WORKSTATION" "$UID_SEL" "  admin: true"
try "downstream true"                   deny  create "${OWN}/d" "$WORKSTATION" "$UID_SEL" "  downstream: true"
try "dnsNames"                          deny  create "${OWN}/dns" "$WORKSTATION" "$UID_SEL" "  dnsNames: [\"vault.${TD}\"]"
try "patch the entry of another owner"  deny  caller patch --dry-run=server clusterstaticentries.spire.spiffe.io "$FIXTURE" --type=merge \
  -p "{\"spec\":{\"spiffeID\":\"${OWN}/stolen\"}}"
try "delete the entry of another owner" deny  caller delete --dry-run=server clusterstaticentries.spire.spiffe.io "$FIXTURE"
try "create ClusterSPIFFEID (RBAC)"     deny  caller auth can-i create clusterspiffeids.spire.spiffe.io --quiet
try "platform operator registration (RBAC)" deny platform auth can-i create clusterstaticentries.spire.spiffe.io --quiet

echo "--- owner glob roles on the Child mount"
mount=$(jq -r '.opgitlab.auth_mount' <<<"$owners")
vault_jwt=$(/usr/local/bin/spire-fetch-platform-foundation-terraform-operator-keycloak-frontend | jq -r .jwt)
for role in $(jq -r '.opgitlab | .operator.role_name, .workload.role_name' <<<"$owners"); do
  try "platform JWT-SVID on ${role}" deny vault write -field=token "auth/${mount}/login" role="$role" jwt=- <<<"$vault_jwt"
done
unset vault_jwt
child_cluster=$(terraform -chdir="$LAYERS/platform-spire-child" output -json foundation_topology | jq -r '.identity.spire.child.cluster_name')
vault read -format=json "sys/quotas/rate-limit/${child_cluster}-opgitlab-terraform-operator" | jq -c '.data | {path, role, rate, interval}'
```

### Step B. Run the Registration Verification

```bash
bash "${VERIFY_DIR}/spire-child-registration.sh"
```

Expected output:

1. The server lists the node attestors `join_token k8s_psat x509pop`, the policy and its binding exist, and the workstation parameter matches an attested agent.
2. The platform operator reports the username of the `keycloak` operator and the group `spire-owner-operator:platform-foundation`, and the owner caller reports the group `spire-owner-operator:opgitlab`.
3. Every registration case outputs `OK`. The three cases inside the owner prefix are admitted, and the remaining thirteen cases are denied by the violated rule. The platform operator holds no grant on `clusterstaticentries`.
4. Both owner roles reject the platform JWT-SVID, and the quota reports the role `opgitlab-terraform-operator` on the Child mount.

### Step C. Remove the Work Directory

```bash
rm -rf "${VERIFY_DIR}"
```

---

## Section 5. Recorded Results

| Date       | Vault   | SPIRE    | `spire-nested` | Kubernetes | Result                                                                                                                                                                            |
| :--------- | :------ | :------- | :------------- | :--------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2026-10-14 | `2.0.4` | `1.15.3` | `0.30.2`       | `v1.36.5`  | All isolation properties verified successfully. Because Vault PKI glob matching crosses dots (`.`), the intermediate CA explicitly excludes platform domains.                     |
| 2026-10-14 | `2.0.4` | `1.15.3` | `0.30.2`       | `v1.36.5`  | Node alias verified across certificate rotation. The live SPIRE Child admits three owner cases, denies thirteen others, and grants the platform no registration.                  |
