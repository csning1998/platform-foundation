# SPIRE Server Migration Runbook

This runbook defines the operational procedure for migrating identities between **SPIRE Parent** and **SPIRE Child**. Identities fall into two categories: Terraform operators and service runtime workloads. This procedure applies across all services and repository owners, including downstream consumers.

---

## Section 1. Scope and Server Assignment

### Item A. Assignment Rules

1. **Deployment Order**:
    - Components deployed **before** SPIRE Child attest to **SPIRE Parent**.
    - Components deployed **after** SPIRE Child attest to **SPIRE Child**.
    - This boundary applies to both Terraform operators and workload identities.
2. **Permanent Parent Operators**: Only `vault-downstream` and `spire-child` remain on SPIRE Parent, as both are deployed before SPIRE Child. The `spire-child` operator deploys SPIRE Child, and the `vault-downstream` operator administers the Downstream Vault.
3. **Atomic Transition**: An identity must move in a single apply sequence and must never remain registered on both servers simultaneously.

### Item B. Declaration Sources

| Identity Type | SPIRE Parent Source                                                        | SPIRE Child Source                                                        |
| :------------ | :------------------------------------------------------------------------- | :------------------------------------------------------------------------ |
| **Operator**  | `_spire_parent_operator_targets` in `provision-spire-parent`               | `_spire_child_operator_targets` in `security-vault-downstream-tenants`    |
| **Workload**  | `issuer = "parent"` under `tenants` in `security-vault-downstream-tenants` | `issuer = "child"` under `tenants` in `security-vault-downstream-tenants` |

- **Identity Derivation**: Both operator target lists derive their concrete identities through `terraform/modules/kvm-provisioning/helpers/terraform-operator-identity`.
- **JWT Mount Mapping**: The `server` attribute of each derived operator determines the Downstream Vault JWT auth mount of the operator.
- **Workload Parameters**: Ansible roles installing workload agents pass `utils_spire_agent_server_kind` and `utils_spire_workload_entry_server_kind`, both of which must match the configured `issuer` of the tenant.

### Item C. Placeholders

| Placeholder   | Description                            | Example                                                                                       |
| :------------ | :------------------------------------- | :-------------------------------------------------------------------------------------------- |
| `<owner>`     | Owner code, equal to `project_code`    | `platform-foundation`, `opgitlab`                                                             |
| `<service>`   | Service catalog name                   | `harbor-origin`, `keycloak`, `cilium`                                                         |
| `<component>` | Component catalog name                 | `frontend`, `hubble`                                                                          |
| `<identity>`  | Full operator identity string          | `<owner>-terraform-operator-<service>-<component>`                                            |
| `<from>`      | Source SPIRE server                    | `parent` or `child`                                                                           |
| `<to>`        | Destination SPIRE server               | `child` or `parent`                                                                           |
| `<mount_to>`  | Target Downstream Vault JWT auth mount | Auth mount for `<to>`                                                                         |
| `<socket_to>` | Target SPIRE agent socket path         | `/run/spire-agent/public/api.sock` (parent), `/run/spire-agent-child/public/api.sock` (child) |

---

## Section 2. Operator Migration

### Step A. Move the Operator Declaration

1. Remove the target component entry from `<from>`.
2. Add the component entry using the same key to `<to>`.
3. Keep `<owner>`, `<service>`, and `<component>` unchanged. This ensures the resulting identity string, wrapper script name, and Vault policy name remain stable.
4. Run the operator unit tests in `tools/platform`:

    ```bash
    go test ./internal/operatorops/
    ```

    The test validates that no duplicate subjects are registered across both target lists.

### Step B. Apply the Operator Migration in Deployment Order

Execute Terraform applies in strict DAG order:

1. `provision-spire-parent` (within the `platform-foundation` Vault Proxy environment).
2. `security-vault-downstream-tenants` (within the `platform-foundation` Vault Proxy environment).
3. `provision-spire-child` (via `platform terraform`).
4. Any affected consumer layers declaring `terraform_operator_subject = { service = "<service>", component = "<component>" }` (via `platform terraform`).

> [!WARNING]
> Terraform operators for the moved component cannot log in from step 1 to step 3 when `<to>` is `child`, because step 1 removes the wrapper and the entry on the Parent. They cannot log in between step 1 and step 2 when `<to>` is `parent`, because the role on the Parent mount appears with step 2. Perform this apply sequence within a single continuous maintenance window.

### Step C. Reconciliation

1. Modifying either operator list alters the `status_trigger` in the runner module of the registering layer, rerunning `playbook_host_terraform_operator.yaml` on the next apply. The reconciliation runs as a task of that playbook.
2. `utils_terraform_operator_identity` (`tasks/reconcile.yaml`) automatically purges the obsolete operator entry from `<from>` and deletes the legacy wrapper script pointing to `<from>`'s socket.
3. The reconciliation task removes the obsolete sudoers drop-in and its corresponding service user.
4. To force a playbook rerun without changing the target list, re-apply with `-replace` on the inventory of the runner module:

| Layer                    | Resource Address                                        |
| :----------------------- | :------------------------------------------------------ |
| `provision-spire-parent` | `module.ansible_operator_identity.local_file.inventory` |
| `provision-spire-child`  | `module.workstation_child_agent.local_file.inventory`   |

### Step D. Verify the Operator Migration

Run these verification checks from the operator workstation. All commands output claims and policy metadata without exposing raw JWTs or Vault tokens.

1. **Verify wrapper socket and audience**:

    ```bash
    grep -E '^SOCKET_PATH=|-audience' /usr/local/bin/spire-fetch-<identity>
    ```

    **Expected**: `SOCKET_PATH` matches `<socket_to>`. The audience is `vault` (for Parent) or matches the `audience` field in `security-vault-downstream-tenants` output `spire_child_jwt_auth` (for Child).

2. **Inspect JWT-SVID claims**:

    ```bash
    /usr/local/bin/spire-fetch-<identity> | python3 -I -c '
    import base64, json, sys

    raw_jwt = json.load(sys.stdin)["jwt"]
    payload_b64 = raw_jwt.split(".")[1]
    padded_b64 = payload_b64 + "=" * (-len(payload_b64) % 4)
    payload = json.loads(base64.urlsafe_b64decode(padded_b64))

    claims = {k: payload[k] for k in ("iss", "sub", "aud") if k in payload}
    print(json.dumps(claims, indent=2))
    '
    ```

    **Expected**: `iss` matches the issuer of `<to>`, and `sub` matches `spiffe://<trust domain>/<owner>/terraform-operator/<service>/<component>`.

3. **Check Vault login coordinates**:

    ```bash
    terraform -chdir=terraform/layers/security-vault-downstream-tenants output -json downstream_vault_operators \
        | jq '.["<service>"]["<component>"] | {auth_mount, role_name, audience, wrapper_name}'
    ```

    **Expected**: `auth_mount` equals `<mount_to>`, and `role_name` equals `<identity>`.

4. **Test Vault authentication and token policies**:
   Ensure `VAULT_ADDR` and `VAULT_CACERT` are configured in your shell:

    ```bash
    vault write -format=json auth/<mount_to>/login role=<identity> \
        jwt="$(/usr/local/bin/spire-fetch-<identity> | jq -r .jwt)" \
        | jq '{policies: .auth.token_policies, ttl: .auth.lease_duration}'
    ```

    **Expected**: `policies` equals `["default", "<identity>"]`, and `ttl` reflects the configured lease duration.

5. **Confirm auth role presence and cleanup**:
   Using a Vault token authorized to list auth roles:

    ```bash
    vault list -format=json auth/<mount_to>/role | jq '[.[] | select(contains("terraform-operator"))]'
    ```

    **Expected**: `<identity>` exists under `<mount_to>`, and no longer appears under `<from>`.

6. **Verify entries on SPIRE Parent**:

    ```bash
    ssh <spire parent ssh host> \
      "sudo spire-server entry show -socketPath /opt/spire/server/data/private/api.sock -output json" \
      | jq -r '.entries[] | select(.spiffe_id.path | test("/terraform-operator/")) | .spiffe_id.path'
    ```

    **Expected**: Lists `/<owner>/terraform-operator/<service>/<component>` if `<to>` is `parent`. The path is absent if `<to>` is `child`.

7. **Verify entries on SPIRE Child**:
   Place the registrar kubeconfig (from `provision-spire-child` output `spire_child_registrar_kv_path`) in a temporary file with permissions `0600`:

    ```bash
    kubectl --kubeconfig <registrar kubeconfig> -n spire-server exec spire-internal-server-0 -c internal-spire-server -- \
      /opt/spire/bin/spire-server entry show -socketPath /tmp/spire-server/private/api.sock -output json \
      | jq -r '.entries[] | select(.spiffe_id.path | test("/terraform-operator/")) | .spiffe_id.path'
    ```

    **Expected**: Lists the path if `<to>` is `child`. The path is absent if `<to>` is `parent`.

    > [!IMPORTANT]
    > Remove the temporary registrar kubeconfig file immediately after running this check.

8. **Validate consumer layer plans**:

    ```bash
    platform terraform plan
    ```

    **Expected**: All layers affected in Step B.4 successfully authenticate and report zero pending changes.

---

## Section 3. Workload Migration

### Step A. Move the Workload Declaration

1. In `security-vault-downstream-tenants`, update the `issuer` of the tenant from `<from>` to `<to>`.
2. Update `utils_spire_agent_server_kind` and `utils_spire_workload_entry_server_kind` in the role responsible for provisioning the workload agent.
3. For services deployed after SPIRE Child (such as `platform_harbor_origin` and `platform_keycloak`), set both variables to `child`.

### Step B. Apply the Workload Migration in Deployment Order

1. `security-vault-downstream-tenants`: Migrates the tenant role to the `<to>` auth mount.
2. `provision-spire-child`: Creates the Child tenant role when `<to>` is `child`, and removes the role when `<from>` is `child`.
3. Component platform layer: Re-runs the agent configuration and workload registration roles.

### Step C. Agent Re-attestation

1. The agent role reads the join token recorded for `<to>`.
2. If `<to>` does not yet recognize the agent, task Step D2d in `utils_spire_agent` clears stale attestation state.
3. The agent re-attests to `<to>` with a fresh join token, and the workload entry role registers the new entry on `<to>`.

### Step D. Verify the Workload Migration

1. **Check agent health**:

    ```bash
    sudo spire-agent healthcheck -socketPath <workload agent socket>
    ```

    **Expected**: `Agent is healthy.`

2. **Verify tenant login coordinates**:

    ```bash
    terraform -chdir=terraform/layers/security-vault-downstream-tenants output -json downstream_tenants \
      | jq '.tenant_login["<tenant name>"]'
    ```

    **Expected**: `auth_mount` points to `<mount_to>`.

3. **Check workload entry on target server**:
   Run the entry inspection command from Section 2 Step D (Item 6 or 7) for the SPIFFE ID of the workload.
   **Expected**: Exactly one entry exists with the workload host agent as parent.

### Item E. Known Gap

Automated reconciliation (Section 2 Step C) applies to operator identities alone. Migrating a workload leaves behind stale agent records and entry definitions on `<from>`. Use the inspection commands in Section 2 Step D (Items 6 and 7) against `<from>` to detect the residue. No workload reconciliation equivalent to `tasks/reconcile.yaml` exists.

---

## Section 4. Reversal

To revert a migration, perform the procedure in reverse by swapping `<from>` and `<to>`. The operational sequence, validation checks, and atomicity requirements remain identical.
