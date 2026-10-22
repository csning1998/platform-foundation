# Platform-Foundation Repository

This repository provides group-scoped governance through several Terraform layers, container services, and shell entry points that provision the GitLab group topology, the shared runner, the SonarQube instance, and the Vault instance supporting this namespace.

## Section 1. Hardware Reference

### Item A. Development machine (for reference only)

- **Chipset:** Intel® HM770
- **CPU:** Intel® Core™ i7-14700HX
- **RAM:** Micron Crucial Pro 64 GB (32 GB × 2) DDR5-5600
- **SSD:** WD PC SN560 1 TB

### Item B. Network Segment & VIP Allocation

| Usage (Service) | Component (Role)         | Network Segment (CIDR) | Service Tier | HA-able? | CoW-able? | VIP            |
| --------------- | ------------------------ | ---------------------- | ------------ | -------- | --------- | -------------- |
| SPIRE Parent    | SPIRE Server (baremetal) | 172.16.125.0/24        | Platform     | False    | Yes       | 172.16.125.250 |
| SPIRE Child     | SPIRE Server (Talos)     | 172.16.126.0/24        | Platform     | True     | No        | 172.16.126.250 |
| Vault           | Vault (Raft)             | 172.16.127.0/24        | Platform     | True     | No        | 172.16.127.250 |
| Harbor Origin   | Harbor (Docker)          | 172.16.128.0/24        | Platform     | False    | Yes       | 172.16.128.250 |
| Cilium Hubble   | Talos (etcd)             | 172.16.129.0/24        | Platform     | True     | No        | 172.16.129.250 |
| Keycloak        | Keycloak (Talos)         | 172.16.130.0/24        | Platform     | False    | No        | 172.16.130.250 |
| HAProxy         | HAProxy (baremetal)      | 172.16.131.0/24        | Platform     | False    | Yes       | 172.16.131.250 |

The segment number follows the deployment order of `planning/architecture_platform-foundation_deployment-chain.md`, which allocates the third octet from 125 upward.

> [!NOTE]
> CoW-able indicates role compatibility with copy-on-write host filesystems. Raft-family consensus engines (such as etcd and Vault Raft) enforce strict fsync latency and quorum-timeout budgets. Intermittent I/O stalls on copy-on-write filesystems risk consensus failures. Kubeadm Master and MicroK8s embed etcd and dqlite with liveness-probe tolerances sufficient to absorb transient I/O latency without hard failures. Copy-on-write storage for these two roles remains permissible subject to operational discretion rather than strict prohibition.

## Section 2. SELinux Configuration

The services defined in `compose.yml` run under rootless Podman on a host with SELinux in enforcing mode. Every bind mount originates from a path beneath the user home directory, whose policy default type is `user_home_t`. A process confined as `container_t` has no access to `user_home_t`, which makes an explicit `container_file_t` label necessary on every mount source.

### Item A. Standing Conventions

Four conventions MUST hold for every service declared in `compose.yml`.

1. **Bind mounts declare no relabel flag**. Neither `:z` nor `:Z` MUST appear on any volume line. Item F documents the incident that motivated this restriction.
2. **The `security_opt: label=disable` setting MUST NOT appear** on any long-running service. Disabling label separation removes confinement outright rather than resolving the underlying label mismatch.
3. **Mount source paths are registered through `semanage fcontext`**. The registration establishes `container_file_t` as the policy default rather than a manually applied label.
4. **Any service that reaches the rootless Podman socket MUST declare `label=type:container_engine_t`**. The policy module under `selinux/` supplies the `connectto` permission required by that type.

### Item B. Registering Persistent File Contexts

1. Registering the mount source paths and applying the labels requires root privileges.

    ```bash
    sudo semanage fcontext -a -t container_file_t "$PWD/(vault|sonarqube|runner-config)(/.*)?"
    sudo restorecon -RFv "$PWD/vault" "$PWD/sonarqube" "$PWD/runner-config"
    ```

2. The `-F` flag is mandatory, because the type `container_file_t` appears in `/etc/selinux/targeted/contexts/customizable_types`, whose entries `restorecon` leaves untouched unless the flag is supplied. Omitting the flag produces `not reset as customized by admin` for each path.

3. A correct label appears as `container_file_t:s0` without any category suffix. An empty category set is dominated by every possible container category, which is why a bare `container_file_t:s0` label remains readable by any of the four services regardless of the category each one receives at its own startup.

4. This step MUST be repeated whenever an unrelated tool recursively relabels a path beneath `vault/`, `sonarqube/`, or `runner-config/`, as described in Item F. No relabel flag on the services' own volumes prevents Podman from reintroducing the problem, but it does not protect against third-party tooling that mounts a broader path.

### Item C. Installing the Policy Module

The default policy grants no `connectto` permission on the container runtime socket to either `container_t` or `container_engine_t`. The module under `selinux/` grants the `connectto` permission to `container_engine_t` alone. Containers of every other type remain unaffected. This mechanism operates at the SELinux type level and is independent of the MCS category handling described in Item B; installing or removing it has no bearing on category drift.

```bash
cd selinux
checkmodule -M -m -o gitlab_runner_podman.mod gitlab_runner_podman.te
semodule_package -o gitlab_runner_podman.pp -m gitlab_runner_podman.mod
sudo semodule -i gitlab_runner_podman.pp
sudo semodule -l | grep gitlab_runner_podman
```

Only `gitlab_runner_podman.te` is tracked in version control. The compiled `.mod` and `.pp` artifacts are build outputs excluded through `.gitignore`.

### Item D. Verification

1. Each container MUST report a non-empty process label. An empty value indicates that label separation is disabled.

    ```bash
    for c in platform-foundation-vault-server platform-foundation-sonarqube-db \
            platform-foundation-sonarqube platform-foundation-gitlab-runner; do
        printf '%s\t' "$c"
        podman inspect "$c" --format '{{.ProcessLabel}}'
    done
    ```

2. The following command reports the distinct set of labels carried by every file beneath the mount sources, a set that MUST contain the single entry `container_file_t:s0` without a category suffix.

    ```bash
    ls -RZ vault sonarqube runner-config | grep -o 'container_file_t:s0[^ ]*' | sort -u
    ```

3. The runner MUST be able to reach the Podman socket. The following request confirms access through an HTTP status of 200.

    ```bash
    podman exec platform-foundation-gitlab-runner \
        curl -s -o /dev/null -w '%{http_code}\n' \
        --unix-socket /run/podman/podman.sock http://d/v1.41/_ping
    ```

### Item E. Diagnosing a Denial

1. Attribution requires the audit log, because access failures appear only as ordinary permission errors inside the container. The following command isolates denials raised by confined container processes.

    ```bash
    sudo ausearch -m avc -ts recent | grep 'scontext=system_u:system_r:container'
    ```

2. Denials raised by `pasta_t` against `config_home_t` or `data_home_t` are unrelated to this configuration. Such denials originate from file descriptors that the rootless network backend inherits from the process that launches Podman.

3. A denial whose `tcontext` carries a non-empty MCS category on a path beneath `vault/`, `sonarqube/`, or `runner-config/` indicates category drift. Item B restores the baseline, and Item F identifies which tool caused the drift.

4. A denial whose `tcontext` names `container_runtime_t` with class `unix_stream_socket` and permission `connectto` indicates that the policy module described in Item C is absent, or that the service omits the `container_engine_t` declaration.

5. The policy default for any path is retrieved through `matchpathcon`, which MUST report `container_file_t:s0` for every registered mount source.

    ```bash
    matchpathcon vault/data sonarqube/data runner-config
    ```

### Item F. Avoiding Recursive Relabeling from Local Tooling

Podman relabel flags `:z` and `:Z` each recursively rewrite the MCS category of every file beneath the mounted path at container start. A tool that mounts the repository root with either flag therefore rewrites `vault/`, `sonarqube/`, and `runner-config/` as a side effect, even when that tool is unrelated to the services defined in `compose.yml`.

This failure was traced to `.githooks/pre-commit` and `.githooks/commit-msg`, each of which ran `podman run -v "${REPO_ROOT}":/repo:Z` on every commit. The recursive relabel left the three service directories with a category that matched neither the hooks' own short-lived container nor any of the four running services, producing denials unrelated to container startup or restart. A resulting denial can cause Vault's raft storage to fail a write, panicking the process and losing the unseal state.

Both hooks read the repository without writing to it and therefore require no relabeling at all. The fix replaces `:Z` with `--security-opt label=disable`, scoped to these two short-lived, non-secret-holding containers, which presents a different risk profile from disabling confinement on a long-running service such as `vault-server`.

Any future local tool that mounts the repository root, or any ancestor of `vault/`, `sonarqube/`, or `runner-config/`, MUST avoid `:z` and `:Z` for the same reason.

### Item G. Relabeling After Repository Relocation

The registration in Item B binds `container_file_t` to a literal path pattern rather than to the repository as a logical entity. Moving or renaming the repository directory leaves the registered rule pointing at a path that no longer exists, while the new path falls back to the parent directory's default type, `user_home_t`, on the next `restorecon` invocation. The policy module installed in Item C is unaffected by relocation, because it grants a permission to the SELinux type `container_engine_t` rather than to any filesystem path.

1. Confirm the current registration before removing it because the deletion in the next step requires a string that matches the one supplied in Item B exactly.

    ```bash
    sudo semanage fcontext -l | grep <PREVIOUS_PATH>
    ```

2. Remove the rule bound to the previous path and register the current path in its place. `<PREVIOUS_PATH>` denotes the absolute path under which the repository resided before relocation.

    ```bash
    sudo semanage fcontext -d -t container_file_t \
        "<PREVIOUS_PATH>/(vault|sonarqube|runner-config)(/.*)?"
    sudo semanage fcontext -a -t container_file_t \
        "$PWD/(vault|sonarqube|runner-config)(/.*)?"
    ```

3. Apply the current registration to the relocated files.

    ```bash
    sudo restorecon -RFv "$PWD/vault" "$PWD/sonarqube" "$PWD/runner-config"
    ```

4. Note that an intra-filesystem move operation (`mv`) MUST preserve the security context associated with each affected inode. Consequently, active containers operating at the time of relocation SHALL continue execution without interruption. Appropriate relabeling MUST be performed prior to any subsequent container recreation, manual execution of `restorecon`, or system-wide SELinux relabel event. In the absence of such relabeling, these operations SHALL resolve paths against the stale registry entries referenced in Item B.

### Item H. Cross-Repository Label Mapping

The conventions specified in Items A through G SHALL apply universally to all local repositories where `.githooks/pre-commit` or `.githooks/commit-msg` access Git metadata under SELinux enforcement. Compliant repositories MUST adhere to a uniform specification by omitting dynamic relabel flags (`:z`/`:Z`), prohibiting `label=disable`, and maintaining a persistent `container_file_t` context registration scoped strictly to the paths required by the container. The table below consolidates all active registrations on this host, sourced from `/etc/selinux/targeted/contexts/files/file_contexts.local`, which ANY local user account MAY read without elevated privileges.

| Repository                              | Registered Path Pattern                                                                               | SELinux Type       | Consumed By                                                  |
| --------------------------------------- | ----------------------------------------------------------------------------------------------------- | ------------------ | ------------------------------------------------------------ |
| `platform-foundation`                   | `` `(vault\|sonarqube\|runner-config)(/.*)?` ``                                                       | `container_file_t` | `vault-server`, `sonarqube`, `sonarqube-db`, `gitlab-runner` |
| `platform-foundation`                   | `.git(/.*)?`                                                                                          | `container_file_t` | `.githooks/pre-commit`, `.githooks/commit-msg`               |
| `gitlab-ci-with-code-reviewer`          | `runner-config(/.*)?`                                                                                 | `container_file_t` | `gitlab-runner`                                              |
| `gitlab-ci-with-code-reviewer`          | `.git(/.*)?`                                                                                          | `container_file_t` | `.githooks/pre-commit`, `.githooks/commit-msg`               |
| `personal/on-premise-gitlab-deployment` | `vault(/.*)?`                                                                                         | `container_file_t` | `iac-vault-server`                                           |
| `personal/on-premise-gitlab-deployment` | `.git(/.*)?`                                                                                          | `container_file_t` | `.githooks/pre-commit`, `.githooks/commit-msg`               |
| `personal/on-premise-agent`             | `` `(vault\|ollama_data\|open-webui_data\|searxng_data\|pipelines\|openclaw\|openclaw_data)(/.*)?` `` | `container_file_t` | Local service bind mounts                                    |
| `personal/on-premise-agent`             | `.git(/.*)?`                                                                                          | `container_file_t` | `.githooks/pre-commit`, `.githooks/commit-msg`               |
| `personal/second-brain`                 | `` `(postgres-data\|db/migrations)(/.*)?` ``                                                          | `container_file_t` | Postgres bind mounts                                         |
| `personal/second-brain`                 | `.git(/.*)?`                                                                                          | `container_file_t` | `.githooks/pre-commit`, `.githooks/commit-msg`               |
| `personal/app-content-matter`           | `.git(/.*)?`                                                                                          | `container_file_t` | `.githooks/pre-commit`, `.githooks/commit-msg`               |
| `personal/LaTeX_Documents`              | `.git(/.*)?`                                                                                          | `container_file_t` | `.githooks/pre-commit`, `.githooks/commit-msg`               |
| `personal/monte-carlo-portfolio-trader` | `.git(/.*)?`                                                                                          | `container_file_t` | `.githooks/pre-commit`, `.githooks/commit-msg`               |
| `template/template-project`             | `.git(/.*)?`                                                                                          | `container_file_t` | `.githooks/pre-commit`, `.githooks/commit-msg`               |
| `template/template-project-fullstack`   | `.git(/.*)?`                                                                                          | `container_file_t` | `.githooks/pre-commit`, `.githooks/commit-msg`               |
| N/A, system-wide                        | `/run/user/1000/podman/podman.sock`                                                                   | `container_file_t` | Rootless Podman socket, independent of any single repository |

Two repositories (`platform-foundation` and `gitlab-ci-with-code-reviewer`) declare the `gitlab_runner_podman` policy module defined in Item C. Each repository MUST maintain an identical module name and version to guarantee standalone deployability independent of pre-existing host-level modules. Accordingly, the `gitlab-runner` service in both repositories SHALL configure `label=type:container_engine_t` rather than disabling security labels.

Repositories lacking a `compose.yml` file SHALL limit context registrations exclusively to `.git(/.*)?`, restricting container execution scope solely to ephemeral Git lifecycle hooks.

The `iac-runner` service within `personal/on-premise-gitlab-deployment` IS EXEMPT from this mapping specification. Due to the operational requirement of bind-mounting `${PROJECT_ROOT}` in its entirety for arbitrary Infrastructure-as-Code (IaC) execution, path-restricted scoping is technically unfeasible; the service MUST retain `security_opt: label=disable`.

Omission of an explicit `restorecon` execution upon removing dynamic relabel flags (`:z`/`:Z`) leaves target files with lingering Multi-Category Security (MCS) attributes rather than restoring the baseline `container_file_t:s0` context. For example, `gitlab-ci-with-code-reviewer/runner-config` previously relied on the `:z` flag; substituting `:z` with `label=type:container_engine_t` caused `config.toml` to retain stale categories (`container_file_t:s0:c206,c409`), resulting in startup permission denials and runner failure. Executing `sudo restorecon -RFv runner-config` resolves this context drift. Consequently, initial migration away from dynamic flags REQUIRES an explicit context restoration alongside the registration procedure specified in Item B.

## Section 3. Terraform Operations

`planning/architecture_platform-foundation_deployment-chain.md` defines the apply order of the layers. This section defines how an operator runs one layer of that order. `documentation/lexicon.md` defines the names which the layers use.

### Item A. Operator Shell

1. The host MUST run the Vault Proxies of `parent-group-governance`, which the first menu item `[Host] Apply All Workstation Prerequisites` of `./governance` installs.
2. The file `.envrc` at the repository root MUST load the environment of the identity `platform-foundation` through `vault-proxy-env`.
3. The environment routes `VAULT_ADDR` to the Proxy of the identity, presents the client certificate of the identity, and exports `TF_HTTP_USERNAME` and `TF_HTTP_PASSWORD`, which the governance Proxy reads from the Bastion Vault.
4. `parent-group-governance/workstation-topology.yaml` declares the port of each Proxy and the path of the state backend token.
5. Each `.envrc` MUST be approved once with `direnv allow`, and direnv loads the environment on every later entry into the directory.
6. The layer `meta-gitlab-project` holds its own `.envrc`, which loads the identity `governance`, since direnv loads the nearest `.envrc` alone.
7. The operator shell MUST export `ANSIBLE_BECOME_PASS` through `read -s`, because a value typed on the command line enters the shell history.
8. Every command of this section MUST NOT print a token or a password.

```bash
cd "$HOME/GitLab/csning1998-lab/platform-engineering-lab/platform-foundation"
direnv allow
printf 'Enter ANSIBLE_BECOME_PASS: '; read -s ANSIBLE_BECOME_PASS; export ANSIBLE_BECOME_PASS; echo
vault token lookup -format=json | jq -r '.data.display_name, .data.policies'
```

The lookup MUST print `cert-operator-platform-foundation` and the policies `platform-foundation-terraform-operator` and `registry-reader-platform-foundation`. A shell without the Proxy environment fails before any Bastion Vault request, and `vault-proxy-env` prints the step which restores the environment.

### Item B. Login per Layer

Every layer of the deployment chain runs correctly inside the Proxy environment of Item A. A layer whose Downstream Vault provider logs in with a JWT-SVID MUST run through `platform terraform`, which fetches the JWT-SVID of the operator which the layer declares in `terraform_operator_subject`.

| Layer                                                                                                                                                                                            | Login                                  | Command, run in the layer directory |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------- | ----------------------------------- |
| `foundation-libvirt-resources`                                                                                                                                                                   | State backend only                     | `terraform`                         |
| `meta-gitlab-project`                                                                                                                                                                            | Governance Proxy                       | `terraform`                         |
| `platform-spire-parent`, `provision-spire-parent`, `platform-haproxy-frontend`, `platform-vault-downstream-frontend`, `provision-vault-downstream-frontend`, `security-vault-downstream-tenants` | platform-foundation Proxy              | `terraform`                         |
| `security-vault-downstream-pki`                                                                                                                                                                  | platform-foundation Proxy and JWT-SVID | `../../../platform terraform`       |
| Every other layer of the deployment chain                                                                                                                                                        | JWT-SVID                               | `../../../platform terraform`       |

A plain `terraform` run in a JWT-SVID layer fails with `required fields are unset: [jwt]`. The `state` subcommands use the state backend only, and plain `terraform state` works in every layer.

### Item C. Plan Review

1. An apply MUST execute a plan which the operator reviewed.
2. A plan which destroys or replaces a `libvirt_domain`, an operating system volume, a `tls_private_key`, or a Vault role MUST NOT be applied.
3. The creation of `libvirt_cloudinit_disk` with an in place update of the cloud-init volume is an expected change after a host reboot.
4. The libvirt provider stores the cloud-init ISO under `/tmp/terraform-provider-libvirt-cloudinit/`.
5. A host reboot empties `/tmp`, since `/tmp` is mounted as tmpfs.
6. A rename of a module call label or a resource label MUST be migrated with a one-time `terraform state mv` before the plan.
7. A `moved` block MUST NOT be committed.

### Item D. Recovery

#### Item D.1. Host SPIRE Agent Without an Identity

1. The symptom is the message `dial unix /run/spire-agent/public/api.sock: connect: no such file or directory` from `platform terraform`.
2. The journal of `spire-agent.service` shows `join token does not exist or has already been used`.
3. The cause is an expired agent SVID after a host outage longer than the SVID lifetime, since a join token is valid for one attestation only.
4. The play of `provision-spire-parent` issues a new join token when the agent health check fails.
5. The play runs only when the inventory file is created or updated.
6. The replacement of the inventory file MUST be requested explicitly.

```bash
cd terraform/layers/provision-spire-parent
terraform plan -replace='module.ansible_operator_identity.local_file.inventory' -out=tfplan
terraform apply tfplan; rm -f tfplan
sudo spire-agent healthcheck -socketPath /run/spire-agent/public/api.sock
```

The health check MUST print `Agent is healthy.`.

#### Item D.2. State Emptied While Resources Remain

1. The symptom is a plan which creates every resource of a layer.
2. The domain of the layer still appears in the output of `virsh -c qemu:///system list --all`.
3. GitLab keeps every version of a state.
4. The last version with resources MUST be pushed back as a newer serial.
5. The lineage of the restored version MUST equal the lineage of the current state.
6. The domain UUID inside the restored version MUST equal the output of `virsh -c qemu:///system domuuid <domain>`.
7. The downloaded state holds secrets.
8. The downloaded files MUST stay in a directory created with `umask 077`.
9. The downloaded files MUST be deleted after the push.

```bash
NAME=<state name>; PROJECT=84608830
S=$(terraform state pull | jq -r .serial)
for v in $(seq "$S" -1 1); do
  n=$(curl -s -H "Authorization: Bearer $TF_HTTP_PASSWORD" \
    "https://gitlab.com/api/v4/projects/$PROJECT/terraform/state/$NAME/versions/$v" | jq -r '(.resources // []) | length')
  echo "serial=$v resources=$n"
done
umask 077; T=$(mktemp -d)
curl -s -H "Authorization: Bearer $TF_HTTP_PASSWORD" \
  "https://gitlab.com/api/v4/projects/$PROJECT/terraform/state/$NAME/versions/<serial>" -o "$T/restore.json"
jq -r '.lineage' "$T/restore.json"
jq -r '.resources[] | select(.type == "libvirt_domain") | .instances[].attributes.uuid' "$T/restore.json"
jq --argjson s "$((S + 1))" '.serial = $s' "$T/restore.json" > "$T/push.json"
terraform state push "$T/push.json"; rm -rf "$T"
```

#### Item D.3. Talos Cluster Without Health

A destroy of an unhealthy Talos cluster MUST pass `-refresh=false`, because `talos_cluster_health` waits until the timeout during a refresh.
