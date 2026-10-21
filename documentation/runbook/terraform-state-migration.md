# Terraform State Security and Operational Governance Runbook

This runbook establishes operational governance procedures, architectural background, and engineering tradeoffs for Terraform state management across `platform-foundation`.

## Section 1. Governance Framework and Architectural Boundaries

### Item A. Scope and Operational Objectives

This runbook governs state management, state migration, and schema synchronization procedures across all Terraform layers within `platform-foundation`. The document formalizes recovery and state cleanup protocols required during repository wide naming migrations, upstream output schema modifications, and out of band compute cluster decommissioning. Operations detailed herein coordinate interactions among Terraform providers, operator workstations, the Bastion Vault, the Downstream Vault, the nested SPIRE architecture, the Harbor Origin OCI registry, and the GitLab HTTP state backend.

### Item B. Upstream Governance Integration and Privilege Domains

Platform operations function within a multi tier privilege model governed by the upstream project. The upstream governance project establishes the authorization boundary dividing infrastructure concerns:

- **Upstream Bastion Vault (L0 to L2)**:

    Protects root cryptographic assets and platform trust facts. The identity `platform-foundation` connects through the loopback mTLS workstation proxy at `127.0.0.1:8211`. The layer `meta-gitlab-project` loads the identity `governance`. The governance proxy listens at `127.0.0.1:8210`. The bootstrap L0 root token resides in `~/.vault-token` on the operator workstation and bypasses every proxy.

- **Downstream Vault (L3 to L4)**:

    Supplies operational secrets, PKI roles, and authentication endpoints for workload components. The layer `security-vault-downstream-tenants` authenticates with the ephemeral root token `ephemeral.vault_kv_secret_v2.downstream_init.data["prod_vault_root_token"]` and runs plain `terraform` under the `platform-foundation` proxy. A later layer which logs in to the Downstream Vault as a component operator MUST run `platform terraform`. `platform terraform` exports the SPIRE JWT-SVID as `TERRAFORM_VAULT_AUTH_JWT`. The layers `platform-spire-parent`, `provision-spire-parent`, `platform-haproxy-frontend`, `platform-vault-downstream-frontend`, and `provision-vault-downstream-frontend` run plain `terraform` under the `platform-foundation` proxy. `provision-spire-parent` declares no Vault provider. `platform-haproxy-frontend` and `platform-spire-parent` declare the default Vault provider. `platform-vault-downstream-frontend` and `provision-vault-downstream-frontend` declare the provider alias `bastion`. None of the five layers logs in to the Downstream Vault with a JWT-SVID. The layer `security-vault-downstream-pki` uses the `platform-foundation` proxy together with the JWT-SVID. The layer `security-vault-downstream-pki` MUST run `platform terraform`.

The naming standard enforces strict alignment between repository names and owner codes. The repository owner code MUST equal the project code (`platform-foundation`). Vault ACL paths use scoped wildcard grants, for example `secret/data/platform-foundation/*`, `auth/oidc/*`, and `auth/platform-foundation-*`. A component operator role MUST restrict `token_policies` and `policies` with `allowed_parameters`. Renaming the project shifts Vault KV secret paths, PKI leaf roles, and OIDC client identifiers to the `platform-foundation/*` hierarchy.

### Item C. State Management and Migration Principles

The GitLab HTTP state backend maintains layer state snapshots under project identifier `84608830`. State snapshots SHOULD NOT store static plaintext credentials or permanent tokens whenever ephemeral mechanisms are supported.

Renaming a module call label or a resource label MUST be migrated with a one time `terraform state mv` prior to plan review. Compute instances, virtual machines, and Talos Kubernetes clusters operate under the disposable cattle principle. When compute entities are decommissioned or replaced out of band, obsolete infrastructure state records MUST be evicted via `terraform state rm`.

## Section 2. Engineering Tradeoffs and Constraint Analysis

### Item A. Access Control Lists and Token Policies

Vault ACL policies enforce scoped path authorization. Downstream Vault operator tokens carry identities granting read and write access to `secret/data/platform-foundation/*`. Policies additionally authorize PKI leaf issuance, OIDC configuration mounts, project specific Kubernetes auth mounts, identity groups, and ACL policies using scoped wildcard paths.

Component operators MUST NOT receive unrestricted root privileges. Component operator roles enforce boundaries using `allowed_parameters` to restrict assignable token policies. The Downstream Vault rejects any read, refresh, or destroy request directed at unmapped legacy paths with HTTP 403 Forbidden. Operators MUST evict obsolete state records using `terraform state rm` when legacy paths cannot be read by scoped credentials.

### Item B. Disposable Infrastructure Rebuild versus In Place Live Migration

Executing in place migrations across interconnected libvirt bridges, virtual machine interfaces, Talos control planes, PKI intermediate authorities, and OIDC client registrations requires complex orchestration scripts and carries substantial risk of persistent state drift.

The platform applies greenfield recreation principles. Compute instances and Kubernetes clusters are treated as disposable entities. A rename of a module call label or a resource label MUST use `terraform state mv` under Section 1 Item C. The operator MUST remove a state address with `terraform state rm` when the Vault path lies outside the scoped token, or when the compute entity was destroyed outside Terraform. Workloads incur planned downtime during layer teardown, and operators MUST clean orphaned hypervisor volumes, bridges, and domain definitions out of band when compute nodes are destroyed outside Terraform lifecycle management.

### Item C. Decoupled Registry Publications versus Remote State Schema Locking

The `data.terraform_remote_state` data source embeds upstream output schemas into downstream state files. When an upstream layer restructures its outputs, Terraform validates expressions against the cached schema during configuration evaluation, causing execution to fail with `Unsupported attribute` before remote state refreshes can execute.

The chosen architecture migrates cross layer operational facts toward decoupled KV publication models governed by upstream standards. In layers retaining `data.terraform_remote_state`, operators MUST evict cached remote state records using `terraform state rm data.terraform_remote_state.<name>` whenever upstream output attributes change. Upstream output structural modifications break downstream plans until cached remote state records are explicitly purged from each downstream state file.

### Item D. Host Cryptographic Trust versus Insecure Transport Flags

The Helm provider OCI registry client cannot accept an inline certificate authority bundle parameter. The platform security baseline strictly prohibits configuring `insecure_skip_tls_verify = true` in any provider or configuration file.

The repository `.envrc` exports `SSL_CERT_DIR` as the `tls/anchors` directory of `security-vault-downstream-pki`. Every Go client, including each Terraform provider, adds the name-constrained frontend trust anchors of that directory to the system CA file, and a rotation of the anchors takes effect at the next run. The operator workstation MUST also synchronize local `/etc/hosts` mappings with libvirt DNS records via `./platform hosts sync --apply` executed from the repository root. Every Downstream PKI rotation or network IP reassignment requires out of band workstation configuration updates before dependent Terraform layers can execute.

### Item E. Ephemeral Secret Usage and State Security Considerations

Harbor robot credentials utilize ephemeral resources (`ephemeral.random_password`) and deliver passwords using write only provider arguments (`secret_wo` in Harbor, `data_json_wo` in Vault), preventing sensitive secrets from entering state files.

In contrast, Keycloak OIDC client registrations currently declare managed `random_password` resources and write client secrets using standard `data_json`, retaining sensitive values inside backend state snapshots. Operators MUST protect GitLab HTTP state backend access to prevent credential leakage.

## Section 3. Failure Mode Matrix and Diagnostic Guide

### Item A. Failure Taxonomy and Remediation Matrix

The following matrix categorizes operational failure modes encountered during platform state evolution, mapping unmitigated impacts to root causes and remedial protocols.

| ID     | Failure Scenario                                        | Unmitigated Impact                                              | Root Cause                                                          | Remedial Protocol                                                      |
| :----- | :------------------------------------------------------ | :-------------------------------------------------------------- | :------------------------------------------------------------------ | :--------------------------------------------------------------------- |
| **F1** | Vault HTTP 403 Forbidden during state refresh           | Terraform halts execution; plan cannot proceed                  | Operator JWT-SVID lacks authorization on legacy paths               | Evict legacy Vault resources using `terraform state rm`                |
| **F2** | Remote state `Unsupported attribute` error              | Downstream plan crashes during expression evaluation            | Downstream state retains stale cached upstream schema               | Evict cached remote state data source via `terraform state rm`         |
| **F3** | Network interface alias collision on multi-homed guests | Secondary network interfaces remain DOWN                        | 15 character Linux interface name limit caused truncation collision | Derive alias format via `helpers/interface-alias`                      |
| **F4** | Helm OCI registry TLS verification failure              | Chart download halts; Kubernetes deployment aborts              | The shell lacks `SSL_CERT_DIR` of the repository `.envrc`           | Allow the repository `.envrc` with `direnv allow`                      |
| **F5** | `terraform destroy` timeout on decommissioned nodes     | Destruction loops indefinitely attempting to reach offline APIs | API endpoints and virtual machines were terminated out of band      | Evict all managed resources from state using `terraform state rm`      |

## Section 4. Standard Operating Protocols

### Step A. Vault Path Mutation Recovery Protocol

When secret paths, PKI roles, or auth mounts are updated to align with current naming conventions, existing state records pointing to legacy paths become unreadable due to scoped operator permissions.

1. From the target layer directory (`terraform/layers/<layer>`), the operator MUST inspect existing state resources using `../../../platform terraform state list`.
2. The operator MUST NOT attempt to execute `terraform destroy` against legacy Vault paths using scoped operator credentials.
3. The operator MUST evict each legacy Vault resource from state:

    ```bash
    ../../../platform terraform state rm <resource_address>
    ```

4. From the same layer directory, the operator MUST execute `../../../platform terraform plan`. A plain `terraform plan` in a JWT-SVID layer fails with `required fields are unset: [jwt]`. `platform terraform` exports `TERRAFORM_VAULT_AUTH_JWT` when the layer declares `auth_login_jwt`. `platform terraform` removes `TERRAFORM_VAULT_AUTH_JWT` for every layer which does not declare `auth_login_jwt`.

### Step B. Upstream Remote State Invalidation Protocol

When an upstream layer modifies its exported output schema, downstream layers referencing the upstream layer via `data.terraform_remote_state` fail expression type checking against cached schemas.

1. From the target layer directory (`terraform/layers/<layer>`), the operator MUST evict the stale remote state data source cache:

    ```bash
    ../../../platform terraform state rm data.terraform_remote_state.<upstream_layer_name>
    ```

2. The operator MUST review updated remote state definitions using `../../../platform terraform apply -refresh-only` rather than unreviewed refresh commands.

### Step C. Compute Entity Eviction Protocol

When a virtual machine or Kubernetes cluster is rebuilt or retired out of band, Terraform cannot reach local guest endpoints or control plane APIs during destroy operations.

1. From the target layer directory (`terraform/layers/<layer>`), the operator MUST inspect the layer state to identify managed resources:

    ```bash
    ../../../platform terraform state list
    ```

2. If control plane endpoints or hypervisor backing resources are no longer operational, the operator MUST NOT execute `terraform destroy`.
3. The operator MUST purge the entire module or individual compute resources from state:

    ```bash
    ../../../platform terraform state rm module.<module_name>
    ```

### Step D. Workstation Environment Synchronization Protocol

Operations dependent on local domain resolution and TLS authentication require synchronization of workstation system stores.

1. From the repository root, the operator MUST synchronize workstation DNS records with libvirt leases prior to executing domain dependent layer commands:

    ```bash
    ./platform hosts sync --apply
    ```

2. The operator MUST run layer commands from a shell which has loaded the repository `.envrc`, since `SSL_CERT_DIR` of the `.envrc` supplies the frontend trust anchors to Harbor OCI operations.

## Section 5. Layer State Remediation Catalog

The following catalog lists state addresses for out of band decommission and for a stale remote state schema. An address which the current configuration still declares returns in the next plan after `terraform state rm`. An address which the current configuration does not declare MUST be removed only when `terraform state list` still prints the address.

Four layers keep a GitLab state object name which differs from the layer directory name. `security-vault-downstream-pki` uses `security-pki`. `platform-vault-downstream-frontend` uses `platform-vault-frontend`. `platform-spire-parent` uses `platform-spire-parent-frontend`. `provision-spire-parent` uses `provision-spire-parent-frontend`. The data source `security_vault_downstream_pki` reads the object `security-pki`.

### Item A. Core Governance and Security Layers

#### Item A.1. Layer meta-gitlab-project

State object name in GitLab backend: `meta-gitlab-project`.

The current configuration declares `module.workload_identity_federation` in `main.tf`. The operator MUST NOT remove `module.workload_identity_federation` as legacy cleanup. Repository history does not record a standalone `vault_generic_secret` address for Workload Identity Federation. From `terraform/layers/meta-gitlab-project`, the operator MUST compare `../../../platform terraform state list` with the current configuration. The operator MUST remove an address only when `state list` prints the address and the current configuration does not declare the address.

#### Item A.2. Layer security-vault-downstream-credentials

State object name in GitLab backend: `security-vault-downstream-credentials`.

Current configuration addresses. Remove a module only when the Vault path lies outside the scoped token, or when the operator decommissions the layer outside Terraform:

```bash
cd terraform/layers/security-vault-downstream-credentials
../../../platform terraform state rm \
  module.credential_harbor_origin_frontend \
  module.credential_keycloak_frontend \
  module.credential_cilium_hubble_ui
```

### Item B. Compute and Networking Tiers

#### Item B.1. Layer platform-spire-child

State object name in GitLab backend: `platform-spire-child`.

Current remote state address. Remove the address when the cached upstream schema is stale:

```bash
cd terraform/layers/platform-spire-child
../../../platform terraform state rm \
  data.terraform_remote_state.security_vault_downstream_tenants
```

#### Item B.2. Layer platform-keycloak-frontend

State object name in GitLab backend: `platform-keycloak-frontend`.

Current Talos, Helm, and remote state addresses. Remove an address for out of band decommission, or remove a remote state address when the cached upstream schema is stale. The data source `security_vault_downstream_pki` reads the GitLab object `security-pki`:

```bash
cd terraform/layers/platform-keycloak-frontend
../../../platform terraform state rm \
    terraform_data.talos_inputs_validation \
    module.credential_keycloak_talos \
    module.establish_platform_keycloak_talos_cluster \
    module.helm_chart_cert_manager \
    module.helm_chart_cilium \
    module.helm_chart_external_secrets \
    module.vault_auth_keycloak_talos \
    data.terraform_remote_state.security_vault_downstream_tenants \
    data.terraform_remote_state.security_vault_downstream_pki
```

#### Item B.3. Layer platform-cilium-hubble

State object name in GitLab backend: `platform-cilium-hubble`.

Current Talos, Helm, and remote state addresses. The data source `security_vault_downstream_pki` reads the GitLab object `security-pki`:

```bash
cd terraform/layers/platform-cilium-hubble
../../../platform terraform state rm \
    module.credential_cilium_hubble \
    module.establish_platform_cilium_hubble_talos_cluster \
    module.vault_auth_cilium_hubble \
    module.helm_chart_cilium \
    module.helm_chart_cert_manager \
    module.helm_chart_external_secrets \
    data.terraform_remote_state.security_vault_downstream_tenants \
    data.terraform_remote_state.security_vault_downstream_pki \
    data.terraform_remote_state.provision_harbor_origin_frontend
```

### Item C. Workload and Identity Provisioning Tiers

#### Item C.1. Layer provision-spire-child

State object name in GitLab backend: `provision-spire-child`.

Current PKI, KV, JWT, and remote state addresses. The data source `security_vault_downstream_pki` reads the GitLab object `security-pki`:

```bash
cd terraform/layers/provision-spire-child
../../../platform terraform state rm \
    vault_pki_secret_backend_role.oidc_discovery \
    vault_pki_secret_backend_cert.oidc_discovery \
    vault_kv_secret_v2.parent_attestor \
    vault_kv_secret_v2.registrar \
    vault_jwt_auth_backend.spire_child \
    vault_jwt_auth_backend_role.tenant \
    data.terraform_remote_state.security_vault_downstream_tenants \
    data.terraform_remote_state.security_vault_downstream_pki
```

#### Item C.2. Layer provision-harbor-origin-frontend

State object name in GitLab backend: `provision-harbor-origin-frontend`.

Current robot credential and remote state addresses:

```bash
cd terraform/layers/provision-harbor-origin-frontend
../../../platform terraform state rm \
    vault_kv_secret_v2.robot_helm_creds \
    data.terraform_remote_state.security_vault_downstream_tenants
```

Harbor provider addresses in the current configuration. Remove the addresses for out of band decommission prior to a fresh provisioning run:

```bash
../../../platform terraform state rm \
    harbor_project.proxy_oci \
    harbor_project.proxy_projects \
    harbor_registry.external \
    harbor_registry.proxy_registries \
    harbor_replication.charts \
    harbor_robot_account.helm_puller \
    harbor_robot_account.helm_pusher
```

#### Item C.3. Layer provision-keycloak-oidc

State object name in GitLab backend: `provision-keycloak-oidc`.

Current Keycloak, Kubernetes, and remote state addresses. The data source `security_vault_downstream_pki` reads the GitLab object `security-pki`:

```bash
cd terraform/layers/provision-keycloak-oidc
  ../../../platform terraform state rm \
    keycloak_group.root_groups \
    keycloak_group.subgroups \
    keycloak_group_roles.grants \
    keycloak_openid_audience_protocol_mapper.vault_audience \
    keycloak_openid_client.clients \
    keycloak_openid_group_membership_protocol_mapper.group_mapper \
    keycloak_openid_user_client_role_protocol_mapper.roles \
    keycloak_realm.infra_realm \
    keycloak_role.client_roles \
    keycloak_user.users \
    keycloak_user_groups.user_assignments \
    kubernetes_manifest.downstream_vault_store \
    kubernetes_manifest.keycloak_credentials \
    kubernetes_namespace_v1.keycloak \
    kubernetes_service_account_v1.external_secrets_vault \
    random_password.client_secrets \
    vault_kv_secret_v2.oidc_clients \
    module.keycloak_listener_certificate \
    module.local_path_provisioner \
    module.manifest_keycloak \
    module.platform_cluster_issuer \
    module.vault_token_reviewer \
    data.terraform_remote_state.security_vault_downstream_tenants \
    data.terraform_remote_state.security_vault_downstream_pki \
    data.terraform_remote_state.platform_keycloak_frontend
```

#### Item C.4. Layer provision-cilium-hubble

State object name in GitLab backend: `provision-cilium-hubble`.

Current Kubernetes, Hubble, and remote state addresses:

```bash
cd terraform/layers/provision-cilium-hubble
../../../platform terraform state rm \
    kubernetes_namespace_v1.platform_lb \
    kubernetes_manifest.lb_ip_pool \
    kubernetes_manifest.l2_announcement_policy \
    kubernetes_manifest.gateway_class \
    kubernetes_service_v1.catalog \
    kubernetes_endpoints_v1.catalog \
    kubernetes_service_account_v1.external_secrets_vault \
    kubernetes_manifest.downstream_vault_store \
    module.hubble_tls_certificates \
    module.kubernetes_cilium_hubble \
    module.platform_cluster_issuer \
    module.vault_token_reviewer \
    data.terraform_remote_state.security_vault_downstream_tenants \
    data.terraform_remote_state.platform_cilium_hubble
```
