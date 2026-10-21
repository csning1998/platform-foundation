# Platform CLI Architecture Specification

`tools/platform` provides an integrated virtualization and infrastructure management tool for `platform-foundation`. The compiled binary MUST reside at the repository root as `platform-foundation/platform`.

## Section 1. System Architecture and Interface Model

### Item A. Dual Entry Point

1. The binary MUST support both direct command execution and interactive menu navigation using shared internal operations.
2. Direct execution MUST follow the syntax `platform <group> <verb> [args] [flags]` for non-interactive and scriptable automation.
3. Invocation without subcommands MUST launch the interactive menu defined in `cmd/platform/menu.go`.
4. Core operational logic MUST reside in the `internal/` packages.
5. The CLI command definitions and interactive menu handlers MUST call identical underlying package functions without duplicating business logic.

### Item B. Build and Execution Constraints

1. The binary MUST be built with `build-platform.sh`, which runs the tests, builds `tools/platform` into `platform-foundation/platform`, and runs the SonarQube scan.
2. `build-platform.sh` MUST read the SonarQube analysis token through the governance Vault Proxy of `parent-group-governance` inside a subshell, and MUST hold the repository values as `readonly` constants.
3. The executable MUST be invoked with the working directory inside the `platform-foundation` repository. `platform terraform` MUST be invoked with the working directory set to a layer directory under `terraform/layers/`.
4. Automatic environment initialization MUST determine `PROJECT_ROOT` from the current working directory.
5. The compiled `platform` binary MUST NOT be tracked in version control and MUST be excluded by `.gitignore`.

## Section 2. Command Reference and Group Specifications

### Item A. Vault Operations (`vault`)

1. The lifecycle of the Bastion Vault, which covers TLS generation, initialization, unseal, and the root token, belongs to `./governance` of `parent-group-governance`.
2. `platform vault status` MUST report the seal state of the Bastion Vault and of the Downstream Vault. The Downstream address and CA come from the outputs of `security-vault-downstream-tenants`.
3. `platform vault unseal-downstream` MUST run `ansible/playbooks/playbook_platform.yaml` with tag `vault-unseal` under the `ansible.cfg` which `ansible-runner` rendered into `platform-vault-downstream-frontend`.
4. `platform vault unseal-downstream` MUST read the inventory from that `ansible.cfg`, and MUST pass the sibling file `inventory-<cluster>-unseal-vars.json` as extra variables.
5. `platform vault unseal-downstream` MUST refuse to run without `VAULT_ADDR`, `VAULT_CACERT`, `VAULT_TOKEN`, `VAULT_CLIENT_CERT`, and `VAULT_CLIENT_KEY` of the `platform-foundation` Vault Proxy, since the play reads the unseal keys from the Bastion Vault through that Proxy.
6. The Talos runtime of the Downstream Vault unseals through transit, hence `platform vault unseal-downstream` serves the VM runtime alone.

### Item B. SSH Operations (`ssh`)

1. `platform ssh keygen [--name <key>] [--overwrite]` MUST generate an unencrypted ed25519 keypair at `$HOME/.ssh/<key>` and persist `SSH_PRIVATE_KEY` in `.env`.
2. `platform ssh keygen` MUST default the key name to `id_ed25519_platform-foundation`.
3. `platform ssh keygen` MUST fail if the target key file exists and `--overwrite` is not asserted.
4. `platform ssh verify` MUST verify strict public-key connectivity to every `Host` declared in configuration files matching `$HOME/.ssh/ssh_*`.

### Item C. Environment Verification (`env`)

1. `platform env verify` MUST verify the availability of `qemu-system-x86_64`, `virsh`, `packer`, `terraform`, `tofu`, `vault`, and `ansible` on `PATH`.
2. `platform env verify` MUST exit with status code 1 if any prerequisite tool binary is missing.
3. `platform env get <KEY>` MUST print the expanded `.env` value of the key alone on standard output, and MUST write the bootstrap messages to standard error.
4. `platform env get` MUST refuse `VAULT_TOKEN` and an undefined key without output.

### Item D. Packer Image Operations (`packer`)

1. `platform packer build <base|all>` MUST clean existing artifacts and execute `packer init` followed by `packer build` for the designated base image.
2. `platform packer clean <base|all>` MUST remove designated build output directories under `packer/output/` and purge non-ISO files from `$HOME/.cache/packer`.
3. `platform packer purge-all` MUST clean all build outputs and host caches across all discovered Packer bases.

### Item E. Terraform Layer Operations (`terraform`, `layer`)

1. `platform terraform [args]` MUST pass every argument to `terraform` unparsed and MUST replace its own process with `terraform` in the current layer directory.
2. For a layer whose Vault provider declares block `auth_login_jwt`, `platform terraform` MUST fetch the JWT-SVID of the layer operator through its wrapper under `/usr/local/bin` and MUST export the JWT-SVID as `TERRAFORM_VAULT_AUTH_JWT`.
3. For every other layer, `platform terraform` MUST remove `TERRAFORM_VAULT_AUTH_JWT` from the environment of `terraform`.
4. `platform terraform` MUST NOT bootstrap `.env`.
5. `platform layer clean <layer|all>` MUST report which layer directories exist under `terraform/layers/`.
6. `platform layer clean` MUST NOT delete a state, because Terraform remote state is stored in the GitLab HTTP backend.
7. Menu option 9 MUST delete the GitLab HTTP backend state of every layer whose backend address a `.tf` file declares, except a layer whose name begins with `administration-`. An administration layer manages the GitLab project which hosts every state.
8. Menu option 9 MUST list the states before deletion and MUST require a second confirmation. Menu option 9 MUST read the GitLab token from `TF_HTTP_PASSWORD` and MUST stop before any deletion when the variable is empty.
9. Menu option 9 MUST resolve the state list before the first confirmation and MUST stop before any purge when the resolution fails, since the libvirt and SSH purges cannot be undone.

### Item F. Libvirt and KVM Operations (`libvirt`)

1. `platform libvirt ensure-services` MUST verify that modular libvirt sockets (`virtqemud.socket`, `virtnetworkd.socket`, `virtstoraged.socket`) are active, starting inactive units via `sudo systemctl start`.
2. `platform libvirt purge` MUST destroy and undefine all domains, storage pools, storage volumes, and virtual networks whose names begin with the `platform-` prefix.
3. `platform libvirt purge` MUST require explicit user confirmation by typing `Y` or `y` prior to resource destruction.
4. Menu option 9 MUST remove, after the libvirt purge, the identity key pair, the Host block file, and the known_hosts file of every cluster under `~/.ssh`, together with each `Include` directive of `~/.ssh/config` which names such a Host block file. A cluster file name carries the `<ProjectCode>-` prefix after `id_<algorithm>_`, `ssh_`, or `known_hosts_`. The shared guest key `id_<algorithm>_<ProjectCode>` MUST remain. `foundation-libvirt-resources` cannot recreate an identity key over an existing file.

### Item G. Strategy Configuration (`strategy`)

1. `platform strategy switch` MUST toggle `ENVIRONMENT_STRATEGY` between `native` and `container`.
2. `platform strategy switch` MUST remove `terraform/.terraform` and `terraform/.terraform.lock.hcl`.
3. `platform strategy switch` MUST recompute `PKR_VAR_NET_BRIDGE` and `PKR_VAR_NET_DEVICE` based on strategy and bridge availability.

### Item H. Workstation Host Resolution (`hosts`)

1. `platform hosts sync` MUST read the DNS host records of every active network on `qemu:///system` and MUST keep the records which carry a host name with prefix `platform-foundation-`.
2. `platform hosts sync` MUST merge the records into one line per address, ordered by address.
3. `platform hosts sync` MUST print the unified diff between `/etc/hosts` and the rewritten block between `# BEGIN platform-foundation` and `# END platform-foundation`, and MUST NOT write without `--apply`.
4. `platform hosts sync --apply` MUST back up `/etc/hosts` to `/etc/hosts.bak` and MUST write the file in place, which keeps its SELinux label.
5. The backup and the write MUST run through `sudo`, and every other step MUST run unprivileged.
6. `platform hosts sync` MUST fail without a write when libvirt returns no record or when the managed block lacks its end line or repeats.
7. `platform hosts sync` MUST NOT bootstrap `.env`.

### Item J. Talos Cluster Sessions (`cluster`)

1. `platform cluster shell <service>/<component>` and `platform cluster status <service>/<component>|all` MUST run in the environment of the platform-foundation Vault Proxy, which supplies the backend credentials and the Bastion Vault route.
2. The target MUST be one `/` between two catalog names of lowercase words joined by single hyphens, and the command MUST reject every other argument without an alias.
3. The commands MUST read the Vault coordinates from one `terraform output -json` of `security-vault-downstream-tenants`, whose output `downstream_vault_operators` names the Vault instance, the KV mount, and the KV path of each `cluster-config` leaf.
4. For a leaf on the Downstream Vault, the commands MUST log in with the JWT-SVID of the operator of the target and MUST verify the listener against `downstream_vault_ca_cert_path`.
5. For a leaf on the Bastion Vault, the commands MUST use `VAULT_ADDR`, `VAULT_CACERT`, `VAULT_CLIENT_CERT`, and `VAULT_CLIENT_KEY` of the Proxy environment.
6. The Downstream Vault token MUST stay inside the process and MUST NOT enter the environment of the session shell.
7. The session files MUST reside in a new directory of mode `0700` below `XDG_RUNTIME_DIR`, or below the temporary directory without `XDG_RUNTIME_DIR`, with mode `0600` for each file.
8. The talosconfig MUST take its endpoints from the InternalIP of the nodes which the API server reports, and MUST omit the endpoints when the API server does not answer.
9. `platform cluster shell` MUST remove the session directory after the shell exits, whatever the exit status.
10. `platform cluster status all` MUST report a target without a `cluster-config` leaf as a component of the VM runtime and MUST continue with the next target.
11. The commands MUST NOT bootstrap `.env`.

## Section 3. Interactive Menu Navigation

### Item A. Menu Structure and Action Mapping

The interactive menu MUST present options in the following sequence:

| Number | Menu Option Label                                          | Target Command                                                  |
| ------ | ---------------------------------------------------------- | --------------------------------------------------------------- |
| 1      | `[Downstream] Unseal Downstream Vault via Ansible`         | `platform vault unseal-downstream`                              |
| 2      | `Generate SSH Key`                                         | Interactive prompt for key name, then `platform ssh keygen`     |
| 3      | `Verify IaC Environment`                                   | `platform env verify`                                           |
| 4      | `Execute Hypervisor Configuration via Ansible`             | `playbook_hypervisor.yaml` against a temporary local inventory  |
| 5      | `Build Packer Base Image`                                  | Packer category submenu                                         |
| 6      | `Verify Guest VM Connectivity via SSH`                     | Confirmation prompt, then `platform ssh verify`                 |
| 7      | `Switch Environment Strategy`                              | `platform strategy switch`                                      |
| 8      | `Purge All Packer Artifacts`                               | `platform packer purge-all`                                     |
| 9      | `Purge All Infrastructure Resources (Libvirt + Terraform)` | `platform libvirt purge`, SSH material, and remote states       |
| 10     | `Quit`                                                     | Terminates menu execution                                       |

### Item B. Packer Submenu Navigation

1. Selection of `Build Packer Base Image` MUST display four category choices: `Base OS Layers`, `Service Layers`, `Build ALL`, and `Back to Main Menu`.
2. `Base OS Layers` MUST enumerate all `*.pkrvars.hcl` files in `packer/distro/` alongside `Build ALL in Base OS Images` and `Back`.
3. `Service Layers` MUST enumerate all `*.pkrvars.hcl` files in `packer/services/` alongside `Build ALL in Service Images` and `Back`.
4. `Build ALL` MUST execute artifact cleanup for all layers, build all distro base layers in alphabetical sequence, and subsequently build all service layers in alphabetical sequence.

## Section 4. Architectural Implementation Strategy

### Item A. Delegation Strategy and Trade-offs

1. Operations MUST use official or standard Go client libraries when direct network APIs exist.
2. Operations MAY delegate to system command-line binaries when no Go library exists or when exact CLI behavior and configuration compatibility must be preserved.

### Item B. Component Implementation Classification

| Subsystem                            | Implementation Mechanism         | Architectural Rationale and Cost Analysis                                                                                            |
| ------------------------------------ | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `internal/vaultops`                  | `github.com/hashicorp/vault/api` | Direct HTTP/TLS API communication without container execution overhead. Requires TLS CA certificate configuration.                   |
| `internal/vaultops` (TLS)            | `crypto/x509`, `crypto/rsa`      | Native standard library execution. Eliminates runtime dependencies on the `openssl` binary.                                          |
| `internal/sshops` (Keygen/Scan)      | `golang.org/x/crypto/ssh`        | In-memory key generation and concurrent TCP host key scanning. Eliminates external shell script forks.                               |
| `internal/sshops` (Verify)           | `ssh` CLI binary                 | Preserves full OpenSSH configuration compatibility (`Host`, `ProxyJump`, `UserKnownHostsFile`). Incurs child process execution cost. |
| `internal/libvirtops` (Purge)        | `libvirt.org/go/libvirt` (CGO)   | Direct RPC interaction with `libvirtd`. Requires system development headers at compile time.                                         |
| `internal/packerops` (Build)         | `packer` CLI binary              | Official CLI automation of HCL templates and plugins. Incurs subprocess management overhead.                                         |
| `vaultops.UnsealProduction`          | `ansible-playbook` CLI binary    | Playbook execution utilizing existing Ansible role collections. Incurs Python interpreter startup overhead.                          |
| `internal/libvirtops.EnsureServices` | `systemctl` CLI binary           | Systemd socket activation management. Avoids heavyweight D-Bus library bindings.                                                     |
| `internal/clusterops`                | `github.com/hashicorp/vault/api` | JWT login and KV reads with CA verification. Delegates `terraform output` and `kubectl get nodes` to the CLI binaries.               |
| `internal/hostsops`                  | `diff`, `sudo cp`, `sudo tee`    | Unprivileged diff and an elevated backup and in-place write. Incurs one `sudo` prompt per applied rewrite.                           |
| `internal/operatorops`               | `terraform` CLI binary, `execve` | Process replacement keeps the JWT-SVID out of every child but `terraform`. Incurs one wrapper run per invocation of a JWT layer.     |

### Item C. Libvirt Resource Cleanup Invariant

1. `virDomainUndefineFlags` in the Libvirt API does not provide a flag equivalent to `virsh undefine --remove-all-storage`.
2. `libvirtops.Purge` MUST destroy and undefine domains with `DOMAIN_UNDEFINE_NVRAM`.
3. Domain disk volumes living in storage pools matching the `platform-` prefix MUST be deleted during the subsequent storage pool iteration sweep.

## Section 5. Configuration and State Management

### Item A. Environment Configuration (`.env`)

1. All environment variable keys read or modified by the application MUST be declared as constants in `internal/config/keys.go`.
2. Variables in `.env` MUST use `KEY="VALUE"` format for interoperability with shell environments.
3. `config.Bootstrap` MUST discover Packer bases from `packer/distro` and `packer/services`, Terraform layers from `terraform/layers`, and Vault Ansible inventory from `ansible/inventory-*-vault-frontend.yaml`.
4. `config.Env.Environ()` MUST expand variable references in the form `${VAR_NAME}` against preceding file keys and the parent process environment.

### Item B. Idempotency Guarantees

1. File modifications to `.env` and `$HOME/.vault-token` MUST be performed via atomic temporary file writes followed by file renames.
2. Token synchronization in `vaultops.SyncToken` MUST enforce file permissions `0600` on `$HOME/.vault-token`.
3. SSH configuration injection in `sshops.AddIncludeConfig` MUST check for line existence before modification to guarantee idempotency across repeated runs.

## Section 6. Build Prerequisites and Compilation Constraints

1. Compiling `internal/libvirtops` REQUIRES the `libvirt-devel` package on Fedora/RHEL systems or `libvirt-dev` on Debian/Ubuntu systems.
2. System dependency installation is automated by Ansible role `ansible/collections/ansible_collections/csning1998_lab/platform_foundation/roles/hypervisor_baseline/tasks/libvirt-dev-headers.yaml`.
3. The build environment MUST support CGO compilation (`CGO_ENABLED=1`).

## Section 7. Quality Assurance and Testing Standards

1. Unit tests MUST NOT depend on active Vault, SPIRE, or Libvirt daemon instances.
2. Unit tests MUST NOT modify paths outside `t.TempDir()`.
3. Filesystem paths, home directories, and operational contexts MUST be passed as explicit parameters to internal packages to enable test isolation.
4. All packages MUST satisfy `golangci-lint` verification with zero errors.
