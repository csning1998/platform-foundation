# Service Catalog and KVM Provisioning Pipeline

This specification establishes the realization requirements from the `service_catalog` declaration to an operational guest virtual machine under the Libvirt provider. The execution flow traverses the module sequence comprising `helpers/service-catalog`, `configure/foundation-resources`, `helpers/terraform-layer-context`, `orchestrate/linux-generic-cluster`, `configure/linux-generic-domain`, and `configure/ansible-runner` under `terraform/modules/kvm-provisioning`, followed by Packer image assembly and Ansible role execution. The `platform-spire-parent` layer serves as the primary implementation reference across this specification. Identical structural requirements govern the companion consumers of `linux-generic-cluster`, including `platform-harbor-origin-frontend`, `platform-keycloak-frontend`, and `platform-vault-downstream-frontend`. Architectural rationale for SPIRE-specific security decisions resides in `documentation/architecture-decision-record/20260830_1530-spire-parent-bootstrap-security-posture.md` and `planning/architecture_platform-foundation.md` Section 9.

## Section 1. Pipeline Topology and Governance Boundary

### Item A. Six-Stage Realization Path

1. Stage 1 (Declaration): The calling layer `terraform.tfvars` MUST declare one `service_catalog` entry per service. The `foundation-libvirt-resources` layer SHALL hold the aggregated catalog for the entire repository.
2. Stage 2 (Pure Computation): The `service-catalog` module MUST derive identity, network, and storage topology from the catalog through Terraform `locals` blocks only. The `service-catalog` module SHALL NOT declare any managed resources.
3. Stage 3 (Foundation Realization): The `foundation-resources` module MUST invoke the `service-catalog` module and SHALL materialize the derived topology into `libvirt_network`, `libvirt_pool`, and `libvirt_volume` resources for every service defined in the catalog.
4. Stage 4 (Per-Layer Projection): Each consuming layer MUST read the foundation outputs through a `terraform_remote_state` data source and MUST pass them to the `terraform-layer-context` module. The `terraform-layer-context` module SHALL resolve local `target_clusters`, `primary_role`, and `service_config` inputs into a layer-scoped context object.
5. Stage 5 (Middleware Orchestration): The `linux-generic-cluster` module MUST flatten per-node compute specifications into a node mapping. The `linux-generic-cluster` module SHALL assemble the Ansible inventory and invoke the `linux-generic-domain` and `ansible-runner` modules.
6. Stage 6 (Guest Realization and Configuration): The `linux-generic-domain` module MUST create the `libvirt_domain` resource from a pre-built Packer base image. The `linux-generic-cluster` module MUST write the guest host keys to a per-cluster `known_hosts` file and MUST verify guest SSH connectivity through the `sshclient_reachability` resource. The `ansible-runner` module MUST execute role-based configuration against the target guest.

### Item B. End-to-End Pipeline Overview

```mermaid
flowchart TD
    subgraph S1 ["Stage 1: Declaration (terraform.tfvars)"]
        SC_VARS["service_catalog\nnetwork_baseline\ndomain_suffix"]
    end

    subgraph S2 ["Stage 2: Pure Computation (modules/kvm-provisioning/helpers/service-catalog)"]
        SC_LOC["Identity Derivation\nNetwork Topology (CIDR/VIP)\nVolume Topology (Cartesian Product)"]
        SC_OUT["topology_identity\ntopology_network\npki_map\nvolume_map\ndns_records"]
    end

    subgraph S3 ["Stage 3: Foundation Realization (layers/foundation-libvirt-resources)"]
        KVM_FOUND["modules/kvm-provisioning/configure/foundation-resources"]
        RES_NET["libvirt_network (NAT & HostOnly)"]
        RES_POOL["libvirt_pool (Directory)"]
        RES_VOL["libvirt_volume.data_disks (5GiB QCOW2)"]
        FOUND_STATE[("Remote State: foundation-libvirt-resources")]
    end

    subgraph S4 ["Stage 4: Per-Layer Projection (layers/platform-spire-parent)"]
        LC_MOD["modules/kvm-provisioning/helpers/terraform-layer-context"]
        LC_OUT["cluster_identity\ncluster_network\ncluster_fqdn\nprimary_network_config\nstorage_pool_name"]
    end

    subgraph S5 ["Stage 5: Middleware Orchestration (modules/kvm-provisioning/orchestrate/linux-generic-cluster)"]
        FLAT["Node Flattening & IP Allocation"]
        VOL_DISC["Storage Volume Auto-Discovery"]
        INV_GEN["Ansible Inventory Assembly"]
    end

    subgraph S6 ["Stage 6: Guest Realization & Runtime Configuration"]
        subgraph CP ["modules/kvm-provisioning/configure"]
            HKVM["linux-generic-domain\n(libvirt_domain)"]
            SSHM["sshclient_reachability\n(known_hosts verification)"]
            ARUN["ansible-runner\n(ansible_playbook_run)"]
        end
        subgraph RUNTIME ["Guest Runtime Execution"]
            VAULT_PKI[("foundation-vault-bastion\n(AppRole & Intermediate CA)")]
            ANS_ROLE["Ansible: platform_spire_parent\n(Mount XFS, server.conf, systemd)"]
            SPIRE_RUN["Operational SPIRE Server\n(Upstream Authority Signed)"]
        end
    end

    SC_VARS --> SC_LOC --> SC_OUT
    SC_OUT --> KVM_FOUND
    KVM_FOUND --> RES_NET & RES_POOL & RES_VOL
    KVM_FOUND --> FOUND_STATE

    FOUND_STATE --> LC_MOD
    LC_MOD --> LC_OUT
    LC_OUT --> FLAT & VOL_DISC & INV_GEN

    FLAT & VOL_DISC --> HKVM
    HKVM -->|guest_host_public_keys| SSHM
    SSHM -->|depends_on| ARUN
    INV_GEN --> ARUN

    ARUN --> ANS_ROLE
    VAULT_PKI -.->|AppRole Authentication| ANS_ROLE
    ANS_ROLE --> SPIRE_RUN
```

### Item C. Global Variable Flow and Data Contract

| Pipeline Stage | Processing Component                  | Input Variables                                                                                                    | Derived Computations                                                                                            | Output Variables / Artifacts                                                                                                          | Consuming Downstream                                  |
| -------------- | ------------------------------------- | ------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| Stage 1 to 2   | `helpers/service-catalog`             | `service_catalog`, `network_baseline`, `domain_suffix`                                                             | `_flat_catalog`, `identity_map`, `network_topology`, `_volume_topology_raw`                                     | `topology_identity`, `topology_network`, `pki_map`, `volume_map`, `dns_records`, `credential_paths`                                   | `foundation-resources`                                |
| Stage 3        | `layers/foundation-libvirt-resources` | `service-catalog` outputs                                                                                          | `segments`, `global_volume_map`, `global_dns_hosts`                                                             | `foundation_topology`, `foundation_network_global`, `foundation_pki`, `foundation_storage`, `foundation_vault_path`, `foundation_ssh` | Consuming service layers via `terraform_remote_state` |
| Stage 4        | `helpers/terraform-layer-context`     | Foundation remote state outputs, `target_clusters`, `primary_role`, `service_config`                               | `segments_map`, `components_context`, `primary_context`, `network_infrastructure_map`                           | `cluster_identity`, `cluster_network`, `cluster_fqdn`, `primary_network_config`, `topology_cluster`, `node_identities`                | Layer `main.tf`, `locals.tf`, `linux-generic-cluster` |
| Stage 5        | `orchestrate/linux-generic-cluster`   | `terraform-layer-context` outputs, `storage_infrastructure_map`, `ansible_template_config`, `ansible_extra_config` | `flat_node_map`, `attached_volumes` (auto-discovery), `ansible_inventory_data`, `hypervisor_kvm_infrastructure` | Provision triggers, rendered `inventory.yaml`                                                                                         | Modules `linux-generic-domain`, `ansible-runner`      |
| Stage 6        | `configure/*` & Ansible               | Provision configurations, base QCOW2 image, Bastion Vault credentials                                              | Copy-on-write OS disk, deterministic MAC derivation, Cloud-init network template                                | Running KVM guest domain, active `spire-server` daemon                                                                                | Operational SPIRE Server, downstream SPIRE agents     |

### Item D. Module Versus Layer Boundary

1. Every component defined from Stage 2 through Stage 6 in Item A MUST function as a repeatable Terraform module. A module SHALL NOT own an independent Terraform state backend.
2. The `platform-spire-parent` component MUST function as an independent layer. The layer SHALL maintain a dedicated backend state address declared in `providers.tf`.
3. The `foundation-libvirt-resources` component MUST function as an independent foundation layer. The layer state SHALL hold every shared `libvirt_network`, `libvirt_pool`, and `libvirt_volume` resource. Consuming service layers MUST NOT declare competing resources for these foundation objects.

### Item E. Ownership Boundary of `service_catalog`

1. The consuming project declaring a `service_catalog` entry MUST maintain ownership of that configuration schema. The `platform-foundation` repository SHALL NOT aggregate distinct project catalogs into a single state file when composite `pki_map` keys risk name collisions across identical service and component pairs.
2. The `platform-foundation` repository MUST define two global parameters consumed across all catalog entries: `network_baseline` and `domain_suffix`. The first segment of every Vault KV path derives from the `project_code` of the catalog entry.
3. Secret material MUST NOT traverse `terraform_remote_state` outputs. The `terraform-layer-context` module SHALL accept `guest_vm_data` and `security_pki_outputs` sourced from a `vault_generic_secret` data source or an authenticated Vault API response.

### Item F. Libvirt Provider Connection

1. The `dmacvicar/libvirt` Terraform provider implements a dedicated RPC client rather than linking against the system `libvirt.so` library, and that client resolves a bare `qemu:///system` URI to a fixed legacy socket path.
2. The host libvirt daemon splits into modular units (`virtqemud`, `virtnetworkd`, `virtstoraged`), and that split removes the legacy compatibility socket on which the bare URI resolution depends.
3. Every layer declaring the `libvirt` provider (`foundation-libvirt-resources`, `platform-cilium-hubble`, `platform-harbor-origin-frontend`, `platform-keycloak-frontend`, `platform-spire-parent`, and `platform-vault-downstream-frontend`) MUST set `uri` to `qemu:///system?socket=/var/run/libvirt/virtqemud-sock`, naming the modular daemon's own socket explicitly through the provider's documented `socket` query parameter.
4. A real `virsh` client resolves the bare `qemu:///system` URI correctly through `libvirt.so`, and that resolution difference confines the explicit socket requirement to the Terraform provider alone.

### Item G. Libvirt Socket Permission Delegation

1. Role `hypervisor_baseline` delegates the legacy `libvirtd.socket` and the three modular daemon sockets (`virtqemud.socket`, `virtnetworkd.socket`, `virtstoraged.socket`) to the `libvirt` group through a matching `SocketGroup=libvirt` and `SocketMode=0770` systemd drop-in for each unit.
2. Role `hypervisor_baseline` adds the operator user account to the `libvirt` group, granting non-root read and write access to every delegated socket.
3. Role `hypervisor_baseline` stops and disables the legacy `libvirtd.service` and the three legacy `libvirtd` socket units since the host runs the modular daemon split rather than the monolithic daemon.
4. A non-root operator invokes `virsh -c qemu:///system` or the Terraform provider's `qemu:///system?socket=...` URI from Item F against the delegated modular sockets without `sudo`, satisfying the non-root access requirement without switching to `qemu:///session`.

### Item H. System Mode Retained over Session Mode

1. `qemu:///session` establishes a fully isolated per-user libvirt instance with an independent storage pool and an independent default network, sharing no state with `qemu:///system`.
2. Session mode's default networking relies on unprivileged usermode networking, and the platform's `service_catalog` and `hypervisor_baseline` firewalld integration depend on a custom bridged, routed, and NAT network topology unavailable without a separate privilege-escalation path, such as a setuid `qemu-bridge-helper` binary.
3. Adopting session mode would require redesigning the network layer rather than migrating existing state since every `libvirt_network`, `libvirt_pool`, and `libvirt_domain` resource under `qemu:///system` is invisible to a session-mode connection.
4. The socket permission delegation in Item G satisfies the non-root access requirement without that redesign, and system mode remains the platform's libvirt connection model.

## Section 2. Service Catalog Specification

Location: `terraform/modules/kvm-provisioning/helpers/service-catalog`. The module accepts `service_catalog`, `network_baseline`, and `domain_suffix` variables, and exposes six structured outputs. The module contains zero `resource` declarations.

### Item A. Input Contract & Schema Specification

| Variable Name      | Type Constraint | Default Value    | Description                                           | RFC 2119 Validation Constraint                                                     |
| ------------------ | --------------- | ---------------- | ----------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `service_catalog`  | `map(object)`   | None (Mandatory) | SSoT catalog declaring services and nested components | Keys MUST match `^[a-z0-9-]+$`. Runtime and Provider MUST belong to allowed enums. |
| `network_baseline` | `object`        | Defined baseline | Global networking baseline parameters                 | CIDR block MUST be valid. `global_mac_prefix` MUST match `XX:XX:XX`.               |
| `domain_suffix`    | `string`        | None (Mandatory) | Base DNS domain suffix for FQDN derivation            | MUST NOT contain leading or trailing dot characters.                               |

1. The `service_catalog` variable MUST conform to `map(object)`. The map key SHALL represent the service name. Each service object SHALL define `owner`, `project_code`, `stage`, and a nested `components` map.
2. Each component object within `components` MUST declare `provider`, `runtime`, `cidr_index`, and `ip_range` containing `start_ip` and `end_ip`. Each component object MAY declare optional `tags`, `node_groups`, `ports`, `data_disks`, `ingress`, and `oidc_client` attributes.
3. The `network_baseline` variable MUST declare `cidr_block`, `host_vip_offset`, `global_mac_prefix`, `global_mtu`, `global_mss`, `node_exporter_port`, and address-space parameters comprising `cidr_subnet_bits`, `cidr_nat_offset`, and `cidr_index_max`.

### Item B. Validation Contract

1. The `service_catalog` variable MUST enforce twelve validation rules prior to graph evaluation. The rules SHALL validate `runtime` enum membership, `provider` enum membership, `stage` enum membership, `cidr_index` range boundaries, global `cidr_index` uniqueness, `end_ip` greater than or equal to `start_ip`, IP host boundary validity between 1 and 254, DNS-safe service naming, DNS-safe component naming, composite key uniqueness, DNS-safe `project_code` naming, and non-empty ingress subdomain declarations.
2. The `network_baseline` variable MUST enforce four validation rules. The rules SHALL validate CIDR format correctness, MAC prefix format matching `XX:XX:XX`, `host_vip_offset` boundaries below 255, and non-overlapping NAT offset calculations.
3. All variable validation blocks MUST complete evaluation before Terraform computes `locals` blocks. A validation failure SHALL terminate plan execution immediately.

### Item C. Identity and Naming Derivation

1. The `_flat_catalog` local MUST merge each service and component pair into a single map keyed by `${service_name}-${comp_name}`. The local SHALL construct `cluster_name` as `${project_code}-${service_name}-${comp_name}`, `storage_pool_name` as `${cluster_name}-pool`, and `hash_prefix` as the first eight hexadecimal characters of `md5(cluster_name)`.
2. The `identity_map` local MUST derive `bridge_name_host` as `vbr${hash_prefix}` and `bridge_name_nat` as `vbr${hash_prefix}-n`. The derived bridge names SHALL depend exclusively on `cluster_name`.
3. The `component_roles` local MUST derive `dns_san` by concatenating ingress subdomains, the shorthand `${service_name}.${stage}.${domain_suffix}` for frontend components, and `${cluster_name}.${stage}.${domain_suffix}`, followed by the `distinct()` operation.
4. The `component_roles` local MUST assign `auth_config.method` to `kubernetes` for `kubeadm` and `microk8s` runtimes. The local SHALL assign `auth_config.method` to `approle` for baremetal runtimes.
5. The `pki_map` output MUST expose the computed role metadata keyed by the composite service-component identifier.

### Item D. Network Topology Derivation

1. The `network_topology` local MUST calculate each component primary CIDR block via `cidrsubnet(network_baseline.cidr_block, cidr_subnet_bits, cidr_index)`. The local SHALL calculate the paired NAT CIDR block at offset `cidr_index - cidr_nat_offset`.
2. The `network_topology` local MUST calculate `vip` as `cidrhost(cidr_block, host_vip_offset)`. The local SHALL compute `node_ips` as the sequential IP range spanning `start_ip` through `end_ip`.
3. The `network_topology` local MUST derive a deterministic segment MAC address from `md5("${cidr_index}${key}")` prefixed with `global_mac_prefix`.
4. The `dns_records` local MUST pair every SAN in `pki_map` with the corresponding segment VIP address.

### Item E. Volume Topology Derivation

1. The `_volume_topology_raw` local MUST compute the Cartesian product of component declarations, node IP ranges, and declared `data_disks` entries. The local SHALL format `volume_name` as `${cluster_name}-node-${node_ip_suffix}-${disk.name_suffix}.qcow2`.
2. The `volume_topology` output MUST index raw volume records by `volume_name`.

### Item F. Output Contract & Transformation Mapping

| Output Variable     | Source Derivation        | Structural Shape                                  | Consuming Module                                  |
| ------------------- | ------------------------ | ------------------------------------------------- | ------------------------------------------------- |
| `topology_network`  | `local.network_topology` | Nested `map(service -> map(component -> object))` | `foundation-resources`, `terraform-layer-context` |
| `topology_identity` | `local.identity_map`     | Nested `map(service -> map(component -> object))` | `foundation-resources`, `terraform-layer-context` |
| `pki_map`           | `local.pki_map`          | Flat `map(cluster_key -> object)`                 | `foundation-resources`, `terraform-layer-context` |
| `volume_map`        | `local.volume_topology`  | Flat `map(volume_name -> object)`                 | `foundation-resources`                            |
| `dns_records`       | `local.dns_records`      | Flat `map(fqdn -> vip)`                           | `foundation-resources`                            |
| `credential_paths`  | `local.credential_paths` | Nested `map(service -> map(component -> string))` | Consuming service layers                          |

1. Outputs `topology_network` and `topology_identity` MUST maintain nesting structured by service name and component name.
2. Outputs `volume_map`, `pki_map`, and `dns_records` MUST expose flat maps keyed by the composite cluster key or volume identifier.
3. The `credential_paths` output MUST expose Vault KV path strings structured as `${project_code}/${service}/${component}`, and each string names the folder of a component. The folder SHALL NOT hold a secret itself. The output SHALL NOT contain plaintext secret data.
4. Output `foundation_vault_path` of layer `foundation-libvirt-resources` MUST expose the leaf paths `kv_paths[service][component][leaf]` structured as `${project_code}/${service}/${component}/${leaf}`. The leaf vocabulary is `ssh`, `cluster-config`, `app`, `addon`, `init`, `join-token`, `registrar`, `parent-attestor`, and `robot`, and the entry `addon` is a prefix which a consumer completes as `addon-<name>`.
5. Output `foundation_vault_path` MUST also expose `ssh_credential_paths`, which resolves to the `ssh` leaf of every SSH-enabled cluster, and `guest_vm_path`, the one project-wide secret which no service owns. Consumers SHALL read these paths and MUST NOT compose them.
6. Each leaf has exactly one writer layer: `security-vault-bastion-credentials` writes the `ssh` leaf and the keepalived password at `haproxy/frontend/app` to the Bastion Vault. `security-vault-downstream-credentials` writes the Hubble UI login at `cilium/hubble/addon-hubble-ui` to the Downstream Vault. The platform layer of a cluster writes the `cluster-config` leaf. Layer `platform-vault-downstream-frontend` writes the `init` leaf. Layer `provision-spire-child` writes the `registrar` and `parent-attestor` leaves. Role `utils_spire_agent` writes the `join-token` leaves below `spire/parent` and `spire/child`.

## Section 3. Foundation Realization: `foundation-resources`

Location: `terraform/modules/kvm-provisioning/configure/foundation-resources`, invoked from the `foundation-libvirt-resources` layer.

### Item A. Global Network and Storage Materialization

1. The module MUST invoke `service-catalog` and re-key outputs by `identity.cluster_name` into the `segments` map.
2. The `libvirt_network.nat_networks` and `libvirt_network.hostonly_networks` resources MUST iterate `network_infrastructure` to create one NAT bridge and one HostOnly bridge per segment. Both network resources SHALL attach `global_dns_hosts` to the `dns.host` configuration block.
3. The `libvirt_pool.storage_pools` resource MUST create one directory-backed storage pool for each distinct `storage_pool_name` derived from the union of `identity_map` and `volume_map`.
4. The `libvirt_volume.data_disks` resource MUST iterate `global_volume_map` and create persistent `qcow2` volumes. The SPIRE Parent 5 GiB data volume SHALL materialize in this foundation layer.
5. A `check` block MUST assert that every `storage_pool_name` conforms to the regular expression `^[a-zA-Z0-9_-]+$` before storage pool creation.

### Item B. Foundation Output Contract

1. Output `foundation_topology` MUST group the topology identity, the topology network, the segments, and the `infrastructure_map`, which merges each segment network definition with its load balancer configuration and backend server list. Consuming service layers SHALL ingest this object.
2. Outputs `foundation_network_global`, `foundation_pki`, and `foundation_vault_path` MUST pass the corresponding catalog outputs and baseline parameters directly to downstream consumers. `foundation_network_global` groups the network baseline, domain suffix, and DNS records, `foundation_pki` groups the PKI settings and the PKI map, and `foundation_vault_path` groups the KV namespace, the credential paths, and the SSH credential paths.
3. Output `foundation_storage` MUST expose the storage infrastructure map and the global volume map for downstream disk auto-discovery.
4. Output `foundation_ssh` MUST expose the local file paths of the SSH client material, keyed by `cluster_name`.

## Section 4. Layer Context: Per-Layer SSoT Projection

Location: `terraform/modules/kvm-provisioning/helpers/terraform-layer-context`. Every caller labels the module `terraform_layer_context`.

### Item A. Context Projection Flow

```mermaid
flowchart LR
    subgraph FOUNDATION_INPUTS ["Foundation Remote State Outputs"]
        G_ID["foundation_topology.identity"]
        G_NET["foundation_topology.network"]
        G_PKI["foundation_pki.map"]
        INF_MAP["foundation_topology.infrastructure"]
    end

    subgraph LAYER_VARS ["Layer-Local Inputs"]
        TC["target_clusters\n(role -> cluster_name)"]
        PR["primary_role\n(e.g., spire-parent)"]
        SC["service_config\n(nodes, vcpu, ram, tier)"]
    end

    subgraph LC_TRANSFORM ["terraform-layer-context Processing"]
        SEGM["segments_map\n(re-keyed by cluster_name)"]
        COMP_CTX["components_context\n(maps target_clusters to segments)"]
        PRIM_CTX["primary_context\n(selects primary_role segment)"]
        NET_TIER["network_infrastructure_map\n(grouped by network_tier)"]
    end

    subgraph LC_EXPORTS ["Layer Outputs"]
        SVC_OUT["cluster_identity\ncluster_network\ncluster_pki_role\ncluster_fqdn"]
        NET_OUT["primary_network_config\nnetwork_tier_topology_map"]
        TOP_OUT["topology_cluster\nnode_identities"]
    end

    G_ID & G_NET & G_PKI --> SEGM
    SEGM --> COMP_CTX
    TC & SC --> COMP_CTX
    COMP_CTX --> PRIM_CTX
    PR --> PRIM_CTX

    INF_MAP --> NET_TIER
    SC --> NET_TIER

    PRIM_CTX --> SVC_OUT
    NET_TIER --> NET_OUT
    COMP_CTX --> TOP_OUT
```

### Item B. Input Contract

1. Input variables `global_topology_identity`, `global_topology_network`, `global_pki_map`, `global_network_baseline`, and `infrastructure_map` MUST match the schema of the corresponding members of the foundation objects `foundation_topology`, `foundation_pki`, and `foundation_network_global`.
2. The `target_clusters` variable MUST map layer-local role names to `cluster_name` strings. The `primary_role` variable MUST identify the primary role key within `target_clusters`.
3. The `service_config` variable MUST define per-role compute parameters including `role`, `network_tier`, `base_image_path`, and `nodes`. Every role key in `service_config` MUST exist in `target_clusters`.
4. Variables `downstream_vault_service_vip` and `security_pki_outputs` MUST default to `null` to accommodate bootstrap layers that execute before Downstream Vault availability.

### Item C. Primary Role Resolution

1. The `segments_map` local MUST index identity and network structures by `cluster_name`.
2. The `components_context` local MUST map every role in `target_clusters` to its resolved segment definition. Outputs `cluster_identity`, `cluster_network`, `cluster_pki_role`, and `cluster_fqdn` SHALL derive from the role specified by `primary_role`.
3. Multi-role layers MUST extract non-primary role definitions directly from `components_context`.

### Item D. Network Tier Grouping

1. The `network_infrastructure_map_grouped` local MUST group infrastructure records by `network_tier`. The `network_infrastructure_map` local SHALL select the initial element of each tier group.
2. The `primary_network_config` output MUST select the infrastructure configuration matching the `network_tier` of `primary_role`.

### Item E. Vault Agent Identity Base

1. The `all_vault_agent_identity_bases` local MUST evaluate to an empty map when `security_pki_outputs` equals `null`.
2. When `security_pki_outputs` contains data, `all_vault_agent_identity_bases` MUST assemble Vault Agent identity structures excluding `secret_id`. The calling layer root module SHALL inject `secret_id` independently.

### Item F. Output Contract

1. The output interface MUST expose `cluster_identity`, `cluster_network`, `cluster_pki_role`, `cluster_fqdn`, `network_infrastructure_map`, `primary_network_config`, `network_tier_topology_map`, `security_vm_credentials`, `downstream_vault_endpoint`, `storage_pool_name`, `topology_cluster`, `node_identities`, `vault_agent_identity_base`, `global_mss`, `global_mtu`, `node_exporter_port`, `primary_context`, `components_context`, `downstream_vault_service_vip`, `all_vault_agent_identity_bases`, and `global_topology_network`.

## Section 5. Linux Generic Cluster: Middleware Orchestration

Location: `terraform/modules/kvm-provisioning/orchestrate/linux-generic-cluster`.

### Item A. Middleware Orchestration Flow

```mermaid
flowchart TD
    subgraph IN_DATA ["Input Data Sources"]
        CTX_TOP["topology_cluster\nnode_identities"]
        NET_INF["network_infrastructure_map"]
        STOR_INF["storage_infrastructure_map\n(Global Volumes)"]
        ANS_CFG["ansible_template_config\nansible_extra_config"]
    end

    subgraph FLATTEN ["Node & Storage Resolution"]
        FNM["flat_node_map\n(Calculates Node IP via cidrhost)"]
        V_DISC["attached_volumes\n(Filter: prefix matching node_name-ip_suffix)"]
        DEVICE_MAP["Device Mapping\n(Assigns /dev/vdb, /dev/vdc sequentially)"]
    end

    subgraph INV_PROC ["Inventory Processing"]
        ROLE_GRP["nodes_by_role Grouping"]
        PRI_SEC["Primary (first host) vs Replica Assignment"]
        VARS_MERGE["ansible_extra_vars Merging\n(Base, Vault, PKI, Generic overrides)"]
    end

    subgraph EXEC_TRIGGER ["Sequential Execution Triggers"]
        H_KVM["configure/linux-generic-domain\n(Creates libvirt_domain)"]
        S_MGR["sshclient_reachability\n(Validates SSH known_hosts)"]
        A_RUN["configure/ansible-runner\n(Executes ansible_playbook_run action)"]
    end

    CTX_TOP & NET_INF --> FNM
    FNM --> V_DISC
    STOR_INF --> V_DISC
    V_DISC --> DEVICE_MAP

    FNM --> ROLE_GRP --> PRI_SEC
    ANS_CFG --> VARS_MERGE

    DEVICE_MAP & FNM --> H_KVM
    H_KVM -->|guest_host_public_keys| S_MGR
    S_MGR -->|depends_on| A_RUN
    PRI_SEC & VARS_MERGE --> A_RUN
```

### Item B. Node Flattening and Volume Auto-Discovery

1. The `flat_node_map` local MUST expand role definitions against declared node maps, generating unique node entries keyed by `${node_name_prefix}-${node_suffix}`. The local SHALL compute node IP addresses via `cidrhost()`.
2. The `attached_volumes` attribute of each node MUST merge explicitly declared volumes with records in `storage_infrastructure_map` matching the prefix `${node_name_prefix}-${ip_suffix}-`. The local SHALL assign sequential `/dev/vd${b..z}` device names to discovered volumes.
3. The `nodes_by_role` local MUST group flattened node definitions by role name for inventory assembly.

### Item C. Ansible Inventory Assembly

1. The `ansible_inventory_data` local MUST assign the lexicographically first node of each role to the `primary` inventory group. The local SHALL assign remaining nodes to the `replica` group.
2. The module MUST pass four standard playbook paths to `ansible-runner`: `playbook_platform.yaml`, `playbook_infra_statesfulsets.yaml`, `playbook_infra_frontend.yaml`, and `playbook_provision.yaml`.
3. The `ansible_extra_vars` local MUST merge extra variable sources applying precedence where the calling layer `ansible_generic_config.extra_vars` overrides default values.

### Item D. Interface Translation and Submodule Triggering

1. The `hypervisor_kvm_infrastructure` local MUST translate foundation network structures into the input schema required by the `linux-generic-domain` module.
2. The module MUST invoke `linux_generic_domain` with `create_networks = false` to prevent duplicate network resource creation.
3. The `local_file.known_hosts` resource MUST write the pre-generated guest host public keys to `~/.ssh/known_hosts_<cluster_name>` before guest network initialization.
4. The `sshclient_reachability.guest_ready` resource MUST depend on `linux_generic_domain` and `local_file.known_hosts`. The `ansible_runner` module SHALL depend on `sshclient_reachability.guest_ready` and SHALL receive the `known_hosts` file ID as its `status_trigger`.

## Section 6. Configure Modules

Location: `terraform/modules/kvm-provisioning/configure`.

### Item A. `linux-generic-domain`

1. The module MUST derive MAC addresses through the `helpers/deterministic-mac` module, which prefixes `52:54:00:` to the first 6 hexadecimal characters of the MD5 digest of each seed. The NAT seed is the node IP, the HostOnly seed is `<node IP>-hostonly`, and each extra network seed is `<node IP>-<network name>`.
2. The `libvirt_volume.os_disk` resource MUST configure `backing_store` referencing the shared base image volume to provide copy-on-write storage optimization.
3. The `libvirt_cloudinit_disk.cloud_init` resource MUST render cloud-init user data and network configurations containing deterministic MAC addresses and static IP assignments.
4. The `libvirt_domain.nodes` resource MUST configure `cpu.mode = "host-passthrough"` and `lifecycle.ignore_changes = [devices]`. The resource SHALL attach network interfaces in fixed order: NAT interface, HostOnly interface, followed by extra interfaces.
5. A `terraform_data.node_mac_uniqueness` resource MUST enforce a precondition verifying MAC address uniqueness across all declared interfaces prior to domain creation.

### Item B. `ansible-runner`

1. The module MUST drive Ansible execution via the `ansible/ansible` provider using `action "ansible_playbook_run"` blocks.
2. The `local_file.inventory` resource MUST trigger playbook execution on `after_create` and `after_update` events. The inventory file SHALL append `jsonencode(var.status_trigger)` in comments to detect upstream virtual machine recreation.
3. The inventory MUST carry the connection variables `ansible_pipelining`, `ansible_ssh_private_key_file`, and `ansible_ssh_common_args` in `all.vars`, and a caller value of the same name MUST take precedence. The module MUST NOT write an `ansible.cfg`, since several instances of the module in one layer share the working directory.
4. Playbook runs MUST resolve the collection of this repository through `ansible/ansible.cfg`, which `ANSIBLE_CONFIG` of the repository `.envrc` names.
5. The `extra_vars` variable MUST declare `sensitive = true` to protect credentials from terminal logging.

### Item C. Module Classification

1. The `configure/linux-talos-domain` and `helpers/talos-interface-planner` modules MUST serve the Talos execution environment through the `orchestrate/linux-talos-cluster` module.
2. The `orchestrate/linux-talos-cluster` module MUST write the Talos `RegistryMirrorConfig` and `RegistryTLSConfig` documents when the caller passes `registry_mirror_config`.

## Section 7. Worked Example: `platform-spire-parent`

Location: `terraform/layers/platform-spire-parent`.

### Item A. Remote State and Authentication Configuration

1. The `data.tf` file MUST declare `terraform_remote_state` data sources named `foundation_libvirt_resources` and `foundation_vault_bastion`, and every layer SHALL read the outputs through `local.state.<layer directory name with underscores>`. The file SHALL declare a `vault_generic_secret.guest_vm` data source reading `secret/platform-foundation/guest_vm`.
2. The `providers.tf` file MUST authenticate the default `vault` provider via `auth/approle/login` using the `platform-foundation` tenant AppRole, read from the objects `bastion_vault_tenant` and `bastion_vault_tenant_credential` that `foundation-vault-bastion` exports.

### Item B. Context and Middleware Invocation

1. The `runtime-generic.tf` file MUST instantiate `module.terraform_layer_context` with foundation outputs, Vault guest credentials, `target_clusters`, `primary_role`, and `service_config`.
2. The `runtime-generic.tf` file MUST instantiate `module.establish_platform_spire_parent_generic_cluster` with `ansible_root_path`, `scripts_root_path`, `storage_infrastructure_map`, and context outputs.

### Item C. Trust Domain and Upstream Authority Derivation

1. The `locals.tf` file MUST extract `spiffe_trust_domain` from `module.terraform_layer_context.cluster_fqdn` via regular expression. Plan evaluation SHALL fail if `cluster_fqdn` deviates from `<service>.<stage>.<domain_suffix>`.
2. The `locals.tf` file MUST resolve `spire_server_port` from `module.terraform_layer_context.primary_network_config.lb_config.ports.api.frontend_port`.
3. The `ansible_template_config.spire_parent_node_ip` variable MUST resolve to `one(module.terraform_layer_context.cluster_network.node_ips)`. The binding SHALL NOT target the load balancer VIP during the bootstrap phase.
4. The `ansible_extra_config` local MUST pass Bastion Vault parameters comprising `spire_vault_upstream_addr`, `spire_vault_upstream_pki_mount_path`, `spire_vault_upstream_approle_mount_path`, `spire_vault_upstream_role_id`, `spire_vault_upstream_secret_id`, and `spire_vault_upstream_ca_cert_b64`. The role ID and secret ID come from the AppRole resources of the same layer, `vault_approle_auth_backend_role.spire_parent_upstream_authority` and its secret ID.

### Item D. Compute Topology

1. The `terraform.tfvars` file MUST configure role `spire-parent` targeting `cluster_name = "platform-foundation-spire-parent"` with base image path `packer/output/base-baremetal-spire-parent/ubuntu-24-base-baremetal-spire-parent.qcow2`.
2. The role MUST declare exactly one node (`00`) with `ip_suffix = 200`, `vcpu = 1`, `ram_size = 512`, and an extra interface on network `vault-bastion-publish` at `172.16.0.10/24`.

### Item E. Output Contract

1. The field `service_vip` of the `generic_cluster` output MUST expose `primary_network_config.lb_config.vip`.
2. The field `node_exporter_targets` of the `generic_cluster` output MUST expose the node IP list and `node_exporter_port`.
3. The `spire_agent_bootstrap` output MUST expose `node_ip`, `trust_domain`, and `server_port` for downstream agent registration.

## Section 8. Image Assembly and Runtime Configuration

### Item A. Packer Base Image Build

1. The `packer/services/base-baremetal-spire-parent.pkrvars.hcl` file MUST source `../output/ubuntu-24-updated/ubuntu-24-updated.qcow2` as the build base.
2. The Packer Ansible provisioner MUST execute role `base_baremetal_spire` from `ansible/playbooks/provision_base_image.yaml`. The role SHALL download SPIRE release `1.15.3`, verify checksum integrity, install `/usr/local/bin/spire-server`, and create the `spire` system account.
3. The role MUST verify the existing binary version via `spire-server --version` and skip download operations when the version matches the target version.
4. The generated image artifact MUST NOT contain runtime service configurations.

### Item B. Playbook Routing

1. The `playbook_platform.yaml` file MUST dynamically map `node_role` to group name `spire_parent`.
2. The playbook MUST target `hosts: "{{ 'spire_parent' if 'spire_parent' in groups else [] }}"` to execute role `platform_spire_parent`.
3. Playbooks lacking a matching `spire_parent` host selector MUST evaluate as no-op executions.

### Item C. `platform_spire_parent` Role Execution

1. The `tasks/main.yaml` file MUST sequence `A-data-disk.yaml`, `B-configure.yaml`, and `C-validate.yaml` inside `block`/`rescue` constructs.
2. The `A-data-disk.yaml` file MUST check mount state via `findmnt`, verify filesystem presence via `blkid`, format missing filesystems with `mkfs.xfs`, and mount `/dev/vdb` to `utils_common_defaults_spire_dir_data` by filesystem UUID.
3. The `B-configure.yaml` file MUST deploy the Bastion Vault listener CA certificate, render `server.conf.j2`, configure the systemd unit `spire-server.service`, and start the service.
4. The `server.conf.j2` template MUST bind `bind_address` to `spire_parent_node_ip`. The template SHALL configure `DataStore "sql"` with `sqlite3`, `NodeAttestor "join_token"`, `KeyManager "disk"`, and `UpstreamAuthority "vault"` using AppRole authentication against Bastion Vault.
5. The `C-validate.yaml` file MUST execute `spire-server healthcheck`, verify certificate presence via `spire-server bundle show`, and assert active authority signing via `spire-server localauthority x509 show`.

### Item D. Systemd Service Hardening

1. The `spire-server.service.j2` template MUST run the service under system user `spire` and group `spire`. The unit SHALL configure `ProtectSystem=full`, `ProtectHome=read-only`, `ProtectClock=yes`, and restrict `ReadWritePaths` to `utils_common_defaults_spire_dir_data`.
2. The unit MUST configure `KillSignal=SIGINT` to ensure graceful process termination.

## Section 9. SPIRE Agent Consumption Contract

Location: `ansible/collections/ansible_collections/csning1998_lab/platform_foundation/roles/utils_spire_agent`.

### Item A. Role Structure

1. Block A MUST install the `spire-agent` binary on the target node at Ansible execution time with SHA-256 verification.
2. Block B MUST create directories `/etc/spire/agent` and `/opt/spire/agent/data`. Block C SHALL configure SELinux file context `container_file_t` over `/run/spire-agent/public` when SELinux is present.

### Item B. Attestation and Token Workflow

1. Block D MUST evaluate the live `spire-agent healthcheck` and set `utils_spire_agent_already_attested` to `true` when the check succeeds. Block D SHALL remove `/opt/spire/agent/data/agent-data.json` when no attested agent runs, because that file holds the identity data of a previous SPIRE Server which the current server cannot verify.
2. Block E MUST execute when `utils_spire_agent_already_attested` is `false`. The block SHALL delegate token generation to `spire_parent_node_ip` via `spire-server token generate`, record the token in Bastion Vault for audit while verifying the listener certificate against the CA file named by `bastion_vault_ca_cert_path`, and execute initial agent attestation.
3. The join token storage path MUST namespace under `spire_cluster_name` and the target hostname.
4. The generated Agent SPIFFE ID MUST embed the join token string. Download workload entries SHALL reference this parent ID.

### Item C. Trust Bundle Distribution

1. Block F MUST retrieve the public trust bundle from `spire_parent_node_ip` via `spire-server bundle show` and write the output to `/etc/spire/agent/bundle.pem`.
2. Block G MUST render `agent.conf.j2` and the systemd unit. Block H SHALL start `spire-agent` and verify health status via `spire-agent healthcheck`.

### Item D. Consuming Layer Requirements

1. A consuming layer `data.tf` MUST declare a remote state data source targeting the state address `platform-spire-parent-frontend`, which layer `platform-spire-parent` keeps after its directory rename. The layer SHALL inject `spire_parent_node_ip`, `spire_trust_domain`, and `spire_server_port` into `ansible_extra_vars`.
2. The consuming layer `terraform apply` MUST execute after the completion of `platform-spire-parent` apply.
3. Consuming Ansible plays MUST gate `utils_spire_agent` execution on the presence of required SPIRE connection variables under the `registered` tag.

## Section 10. Current Implementation Status

### Item A. Verified and Operational Components

1. The `platform-spire-parent` layer is deployed. The `spire-server` process runs under systemd, and local health checks confirm intermediate CA signing via the Bastion Vault upstream authority.
2. The Workload API socket directory `/run/spire-agent/public` is verified on Ubuntu guest hosts.
3. The `utils_spire_agent` role is verified in `platform_harbor_origin` with successful node attestation under trust domain `spiffe://production.example.com`. The operator host attests under trust domain `spiffe://production.homelab-infra.dev` after the rebuild of the Bastion Vault.

### Item B. Pending Components

1. Consumption of the SPIRE workload identity by `platform_harbor_origin` through `utils_vault_agent` remains pending until the Harbor Origin deployment.
2. The operator identities for Cilium, HAProxy, Harbor Origin, and Downstream Vault log in to Bastion Vault through the OIDC Discovery Provider, which the verification play of `playbook_host_terraform_operator.yaml` confirms.
3. Deployment of the SPIRE Nested Server tier on Talos remains pending control plane readiness.
4. Deployment of the non-attestable external caller mTLS gateway remains outside the current platform development scope.
