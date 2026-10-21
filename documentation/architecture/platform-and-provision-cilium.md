# Platform and Provision Cilium Hubble

This layer provisions a Talos Linux cluster replacing `platform-haproxy-frontend` as the Central Load Balancer, with strategic justification documented in `documentation/architecture-decision-record/20260813_1630-clb-migration-to-talos-cilium.md`. This specification captures technical implementation constraints unexpressible in HCL configuration.

## Section 1. Platform Cilium Layer

### Item A. Layer Contract

Ownership boundaries, downstream output interfaces, and catalog constraints constitute the contractual interface consumed by dependent layers.

1. Ownership Split. Layer `platform-cilium-hubble` manages guest virtual machines, Talos machine configurations, and the Cilium bootstrap manifest, while `provision-cilium-hubble` manages Kubernetes API resources requiring an active control plane. This separation maintains architectural symmetry across repository platform and provision pairs.
2. Downstream Output Names. Layer `platform-cilium-hubble` exports the output `talos_cluster` with the fields `hostonly_addresses`, `bootstrap_node_key`, `cluster_issuer`, and `external_secrets`, and the output `hubble_tls_certificates`. Consumers MUST read topology and global facts from the state of `foundation-libvirt-resources` directly.
3. Catalog Projection. The `segments_map` structure is duplicated from `platform-haproxy-frontend` as a service catalog property, decoupled from specific HAProxy or Cilium load-balancer implementations. Short identifiers in `var.node_config` (e.g., `00`) are expanded into fully qualified hostnames (e.g., `platform-foundation-cilium-hubble-node-00`), exposing strictly qualified keys to downstream modules.
4. Resolved SSoT Reservation. Earlier revisions omitted the Central Load Balancer cluster from `network_service_segments`, leaving the cluster endpoint bound to a single node address without a Single Source of Truth (SSoT) IP reservation. The service catalog declares the `cilium` segment with an explicit `cidr_index`, and `network_segments_map` propagates the resulting VIP into this module. Item C describes the endpoint binding that consumes the reservation.

### Item B. Bootstrap Sequence

Cilium MUST achieve active state prior to Kubernetes API availability. The bootstrap sequence defines the image and chart source, the CNI manifest injection path, Talos-specific Helm parameters, Hubble certificate issuance for render stability, and post-installation address handoff procedures.

1. Cilium Injection Through Inline Manifests. Direct installation via `helm_release` is impossible during initial provisioning because the Kubernetes API server is offline. Instead, module `kubernetes-addons/helm-chart-cilium` renders the chart locally through `data.helm_template.cilium` for injection via `cluster.inlineManifests`, enabling Talos to apply the CNI manifest during early node initialization before API availability. To align with Sidero Labs production recommendations, `cluster.network.cni.name` is set to `none` and `cluster.proxy.disabled` is set to `true`.
2. Cilium Values Required by Talos. Because Talos restricts the `SYS_MODULE` capability from workloads, Helm configuration explicitly defines required system capabilities while disabling `cgroup.autoMount` to leverage host-managed `cgroupv2` and `bpffs` mounts. With `kube-proxy` disabled, `k8sServiceHost` and `k8sServicePort` route traffic through the node-local KubePrism endpoint (`localhost:7445`, matching `machine.features.kubePrism.port`) to ensure API connectivity prior to CNI initialization. Setting `ipam.mode` to `kubernetes` alongside `kubeProxyReplacement` and `l2announcements` enables direct service VIP broadcasting across attached network bridges.
3. Hubble With Externally Issued Certificates. Hubble relay and UI are enabled (`hubble.enabled = true`) with `hubble.tls.auto.enabled = false`. The chart mounts the Secrets `hubble-server-certs` and `hubble-relay-client-certs` through `existingSecret`, and layer `provision-cilium-hubble` issues both Secrets with a P-256 key through the in-cluster ClusterIssuer, from the Downstream PKI role which layer `platform-cilium-hubble` owns through module `vault-kubernetes-auth`. The `helm` method emits a new self-signed CA on every stateless `helm_template` render, and embedding that CA in `cluster.inlineManifests` produces spurious `machine_configuration_hash` diffs. The `certmanager` method of chart 1.20.2 renders a second `privateKey` key after `hubble.tls.auto.privateKey`, and the later key drops the ECDSA algorithm, which the P-256 role then rejects.
4. eBPF Masquerading. Helm value `bpf.masquerade` resolves to `true`, the configuration validated for in-cluster traffic on this cluster. The setting does not resolve SNAT toward external bare-metal backends, because one direct-routing device per node is an architectural constraint of Cilium. HAProxy serves those backends instead (`decisions.md`, external bare-metal services).
5. Address Handoff After Installation. Initial node configuration (`talos_machine_configuration_apply`) reaches maintenance-mode nodes via temporary NAT DHCP leases, whereas post-installation bootstrapping (`talos_machine_bootstrap`) and health probes target static HostOnly addresses. Resource creation timeouts accommodate disk installation reboots and non-bootstrap etcd cluster joins up to `constants.EtcdJoinTimeout` (30 minutes in Talos v1.13.8), while health check deadlines account for container image retrieval required for CNI-dependent kubelet readiness.
6. Image and Chart Source. Harbor Origin precedes Cilium and is reachable through the HAProxy VIP. Module `linux-talos-cluster` writes one `RegistryMirrorConfig` per upstream registry domain, pointing at the Harbor Origin proxy cache project with `overridePath = true`, and one `RegistryTLSConfig` holding the Downstream PKI trust bundle. Module `helm-chart-cilium` pulls the chart from `helm_config.chart_repository`, the private Harbor Origin `helm-charts` OCI project, and the layer authenticates the helm provider with the puller robot through an ephemeral Downstream Vault read. The OCI registry client of helm provider 3.0.2 accepts no CA. The repository `.envrc` MUST export `SSL_CERT_DIR` as the `tls/anchors` directory of `security-vault-downstream-pki`, which holds `frontend-trust-anchors.crt` alone. The file holds `pki-intermediate-vault-downstream` and `pki-leaf-platform`, and the name constraints of both intermediates bound the trust to `homelab-infra.dev` and the platform address range. The Go `crypto/x509` package adds the files of `SSL_CERT_DIR` to the system CA file and enforces the name constraints of each anchor, and the helm provider inherits the variable from Terraform. The operator host trust store stays unchanged, and a rotation of the anchors takes effect at the next run.

### Item C. Guest Topology

Node roles, network interface ordering, and boot media configuration define the topology contract shared between `lb-interface-planner` and `hypervisor-kvm-talos`.

1. Control Plane Membership. The cluster provisions a 3-node topology where all nodes act as control plane members to satisfy etcd quorum requirements for combined control plane and data plane execution. The lowest lexicographically sorted node key designates the etcd bootstrap target. Network creation is omitted (`create_networks = false`), deferring interface lifecycle management to `foundation-libvirt-resources`.
2. Control Plane Endpoint. The `cluster_endpoint` local MUST resolve to the catalog VIP (`local.svc_net.vip`) rather than to any individual node address. Document `LinkAliasConfig` names the index 1 HostOnly interface `hostonly` by MAC address, and document `Layer2VIPConfig` binds the VIP to that alias. Talos leader election then moves the address between control plane members. A node failure therefore leaves the endpoint reachable without a Terraform apply.
3. Return Path of HostOnly Addresses. A Talos node holds a direct leg on each service segment, such as `172.16.127.0/24` of the Downstream Vault. A reply from the HostOnly address or the VIP to a peer on such a segment would leave through the direct leg and bypass the host, and the host conntrack then drops the next forwarded packet of the connection as invalid. Document `RoutingRuleConfig` sends every packet sourced from the HostOnly subnet and destined to a platform network (`platform_route_cidrs`) to table 100, which holds the HostOnly subnet itself and a default route through the HostOnly gateway. The rule MUST carry the destination prefix, since replies to pods carry a HostOnly source and the pod routes live in the main table alone. The TokenReview callback of the Downstream Vault to the VIP depends on this return path.
4. Interface Order. Interfaces generated by `lb-interface-planner` follow a strict structural order.
    1. Index 0 (NAT interface): Configured via DHCP for early maintenance-mode provisioning (`talos_machine_configuration_apply`). The machine configuration MUST declare the interface with `dhcp: true`, since a node which carries network documents runs DHCP on declared interfaces alone, and every later apply reaches the node on this lease.
    2. Index 1 (HostOnly interface): Binds the static host IP address, the Kubernetes API control endpoint, and the Talos-managed control plane VIP.
    3. Index 2+ (Service segments): Assigns segment-specific static IPs calculated from `ip_suffix`.

    The `interface_planner` consumes `var.talos_iso_path` via the required `base_image_path` attribute, preserving shared MAC address and interface mapping logic with legacy `cloud-init` workflows.

5. Lease Acquisition Gate. The `wait_for_ip` block MUST apply to the index 0 NAT interface alone, with a 300 second timeout against the DHCP lease source. Domain creation therefore completes only after the maintenance-mode address becomes reachable, which is the address `talos_machine_configuration_apply` targets. Interfaces at index 1 and above carry static addresses, which never depend on a lease.
6. Disk and Boot Media. Operating system volumes deploy as empty `raw` disks that Talos partitions dynamically upon receiving configuration, bypassing `cloud-init`. Item D states the reason the format is `raw` rather than `qcow2`. Initial boot falls through from empty disk `vda` to the attached read-only ISO installer, while `talos.halt_if_installed` prevents secondary installations on subsequent reboots. To prevent persistent state drift in Terraform, `libvirt_domain.devices` changes are ignored post-creation, and network interface queries reference domain UUIDs rather than transient numeric runtime IDs. A subsequent topology change to `node_config` falls under the same ignore rule and requires `terraform apply -replace` against the affected node.

### Item D. Consensus Storage and Scheduling Stability

The disk format decision recorded in commit `591b1ae` propagates into scheduling and timeout constraints. Each requirement below traces back to the fsync sensitivity of etcd.

1. Copy-on-Write Exclusion. The `backing_store` attribute of `libvirt_volume` implements Copy-on-Write by layering a thin overlay above a shared base image, and the attribute accepts `qcow2` alone. Guests running a consensus protocol MUST declare `os_disk_format = "raw"`, because the Copy-on-Write layer introduces metadata write amplification and latency variance on the fsync path that etcd and Vault Raft interpret as storage failure. The service catalog assigns `raw` to `cilium` and `vault`, and assigns `qcow2` to `spire-parent`, `harbor-origin`, and `keycloak`, which never run a consensus protocol and therefore retain thin provisioning together with snapshot capability.
2. Raw Volume Population. A `raw` volume forfeits the base image overlay and materializes empty at the declared capacity. Guests other than Talos require an Ansible role to populate the volume through `qemu-img convert` before first boot, and `start_domains` gates domain startup until that population completes. Talos never requires a population step, because Talos partitions and installs onto an unformatted volume after receiving machine configuration.
3. CPU Pinning. Module `hypervisor-kvm-talos` MUST pin every guest vCPU to a dedicated physical core. The `talos_core_base` local subtracts the total vCPU count of the cluster from `data.libvirt_node_info.host.cpu_cores_total`, placing the allocation at the highest core indices. The `talos_node_core_offset` local then assigns each node a contiguous non-overlapping range by accumulating the vCPU counts of preceding nodes in sorted key order, and `cpu_tune.vcpu_pin` binds vCPU `i` of a node to physical core `offset + i`. Unpinned domains concentrate toward low-numbered cores under the default Linux scheduler, and the resulting contention produces the scheduling jitter that etcd reports as peer timeouts.
4. Etcd Timeout Widening. The `cluster.etcd.extraArgs` block MUST raise `election-timeout` to 2500 milliseconds and `heartbeat-interval` to 250 milliseconds above the Talos baseline. Pinning reduces the jitter source, and the widened timeouts raise tolerance for the residual jitter that a shared hypervisor cannot eliminate.
5. Reboot Apply Mode. Resource `talos_machine_configuration_apply` MUST declare `apply_mode = "reboot"`. An in-place reconfiguration cannot reconcile an etcd learner that already holds inconsistent in-memory state, and a full node restart discards that state.

## Section 2. Provision Cilium Layer

### Item A. Control Plane Access

Binds Kubernetes API clients strictly to the kubeconfig which `platform-cilium-hubble` writes to the Downstream Vault, isolating Talos OS credentials from Kubernetes object provisioning.

1. Remote State Source: `terraform_remote_state.platform_cilium_hubble` reads the fields `hostonly_addresses`, `cluster_issuer`, and `external_secrets` of the output `talos_cluster`, and the output `hubble_tls_certificates`. Block `ephemeral.vault_kv_secret_v2.cilium_hubble` reads the kubeconfig from the Downstream KV leaf `cilium/hubble/cluster-config`, which keeps the credential out of Terraform state. Topology facts come from the state of `foundation-libvirt-resources`.
2. Credential Partitioning: Local `api_server_connection` decodes the kubeconfig into `host`, `ca_cert`, `client_certificate`, and `client_key`. Unused Talos `client_configuration` isolates OS-level `apid` credentials from Kubernetes control-plane credentials.
3. Provider Binding: Provider `hashicorp/kubernetes` serves both typed resources (`kubernetes_namespace_v1`, `kubernetes_service_v1`, `kubernetes_endpoints_v1`) and untyped Cilium custom resources through `kubernetes_manifest`. Provider `gavinbunney/kubectl` is removed, and the `manifest` attribute accepts a native HCL object where `kubectl_manifest` required a `yamlencode` string.
4. Vault Authentication: Provider `vault.downstream` is the only Vault provider of the layer. The provider MUST authenticate through block `auth_login_jwt` with the JWT-SVID of the SPIRE Parent, against the mount and role of `downstream_vault_operators["cilium"]["hubble"]` in the output of layer `security-vault-downstream-tenants`, which the layer selects through `terraform_operator_subject`. The operator runs terraform through `platform terraform`, which invokes wrapper `spire-fetch-platform-foundation-terraform-operator-cilium-hubble` and exports the JWT as `TERRAFORM_VAULT_AUTH_JWT`. The JWT therefore never enters a plan or the state.
5. Downstream Vault Targets: Module `vault-token-reviewer`, the ClusterIssuer, the two Hubble mTLS certificates, and the ClusterSecretStore `downstream-vault` target the Downstream Vault. Module `platform-certificate` issues the Secrets `hubble-server-certs` and `hubble-relay-client-certs` with a P-256 key, which the Cilium chart mounts through `existingSecret`.

### Item B. Apply-Time Health Gate

Kubernetes object creation MUST NOT proceed against a control plane whose quorum is still converging.

1. Ephemeral Health Probe: The `ephemeral "talos_cluster_health" "this"` block validates every control plane node at apply time, with a 10 minute timeout. Client credentials come from `ephemeral.vault_kv_secret_v2.cilium_hubble`, keeping the Talos CA certificate, client certificate, and client key out of Terraform state.
2. Dependency Edges: Resources `kubernetes_namespace_v1.platform_lb`, `kubernetes_manifest.lb_ip_pool`, and `kubernetes_manifest.l2_announcement_policy` MUST each declare `depends_on` against the health probe. Concurrent disk activity from sibling layers applying against the same hypervisor destabilizes etcd consensus, and Section 1 Item D records the storage decision that produces that sensitivity. The probe converts a transient quorum loss into an explicit apply failure rather than an opaque Kubernetes API error.

### Item C. Resource Ownership

Defines cluster-scoped Cilium resources and namespaced Services per ownership boundaries in ADR `20260813_1630-clb-migration-to-talos-cilium.md`.

1. Cluster-Scoped Custom Resources: Provisions `CiliumLoadBalancerIPPool` and `CiliumL2AnnouncementPolicy` (`<project_code>-catalog`). Both match `spec.serviceSelector.matchLabels` (`platform.io/lb-managed=cilium-hubble`), isolating managed allocations from external workloads.
2. Project-Scoped Service Objects: Consuming projects own respective `kubernetes_service` and `kubernetes_endpoints` resources. This layer generates those objects for `platform-foundation` catalog entries, as `platform-foundation` acts as the consuming project for bare-metal services.
3. Namespace Isolation: Encapsulates generated objects within namespace `platform-lb`. Output `cilium_hubble_fronted_service_vips` exposes allocated VIPs keyed by catalog segment.

### Item D. Catalog Fronting

Local `fronted_segments` maps `foundation_topology.infrastructure` entries to selector-less `LoadBalancer` Services backed by catalog bare-metal guest IP endpoints.

1. Segment Exclusion: Omits the key matching `foundation_topology.identity["cilium"]["hubble"].cluster_name` to eliminate circular routing and self-referential load balancing, and keeps only segments whose runtime is Kubernetes-native (`talos`, `kubeadm`, `microk8s`, `minikube`), because `platform-haproxy-frontend` exposes every other runtime.
2. Selector-less Service Pair: `kubernetes_service_v1.catalog` sets `type = LoadBalancer` without pod selectors, linking to a matching `kubernetes_endpoints_v1.catalog` object. Endpoint target addresses iterate over `backend_servers`; Service ports bind `frontend_port` and forward to `backend_port`.
3. VIP Allocation: Annotation `io.cilium/lb-ipam-ips` requests `lb_config.vip` per Service, with pool `spec.blocks` assigning corresponding `/32` CIDR prefixes. Field `spec.loadBalancerIP` remains unset per Kubernetes v1.24 deprecation. `CiliumL2AnnouncementPolicy` sets `loadBalancerIPs = true` to enable Layer 2 VIP advertisement.

### Item E. Hubble UI Exposure

Module `kubernetes-addons/cilium-hubble` exposes the Hubble UI through the Gateway API behind oauth2-proxy.

1. Chart Ownership: The Cilium chart deploys the Hubble UI. The Cilium Helm repository publishes the `cilium` and `tetragon` charts alone. The module therefore carries the ingress objects without a chart release.
2. Module Scope: The module owns the namespace `platform-hubble`, the address pool and L2 announcement of the Hubble UI VIP, the Certificate, the ExternalSecret, the oauth2-proxy Deployment and Service, the Gateway, and the HTTPRoute.
3. Layer Scope: Layer `provision-cilium-hubble` owns the GatewayClass `cilium`, the ClusterIssuer, and the ClusterSecretStore. The module receives each of the three objects as a reference.
4. Credential Source: The ExternalSecret reads the single KV path of the field `external_secrets.kv_paths` of the output `talos_cluster` from the Downstream Vault. Layer `security-vault-downstream-credentials` writes that path. The Vault policy of the External Secrets Operator grants read access to that path alone.

## Section 3. Health Gate Diagnosis

A timeout of `data.talos_cluster_health.this` does not identify a root cause. The diagnosis procedure isolates the fault by elimination across the hypervisor layer, the guest layer, and the network layer. Each step MUST pair a hypothesis with a metric which can falsify the hypothesis. Every command in this section MUST remain read only.

### Item A. Hypervisor Layer

1. Disk Throughput. The delta of `/proc/diskstats` over a fixed interval measures NVMe write volume and utilization. A utilization near zero falsifies disk saturation as the cause of etcd latency.
2. Pressure Attribution. The global value of `/proc/pressure/io` MUST NOT serve as sole evidence. The `io.pressure` file of each `machine.slice` scope attributes stall time to one guest domain. Stall time confined to `user.slice` is unrelated to the cluster.
3. CPU Contention. The `vcpupin` elements of `virsh dumpxml` expose the physical core range of each node. Deltas of `/proc/stat` on the pinned cores measure host CPU contention.

### Item B. Guest Observation Without Credentials

The steps in Item B require neither a Talos client credential nor a kubeconfig.

1. Console Capture. Command `virsh screenshot` captures the Talos dashboard of each node. The dashboard log exposes etcd health check results, controller errors, and VIP reachability.
2. Port Probes. TCP probes against ports 50000, 6443, and 2379 on each HostOnly address and on the VIP locate the stalled bootstrap stage. An anonymous API server request returns HTTP 401 under Talos defaults. The HTTP 401 response does not carry health information.

### Item C. Credential Recovery

1. Vault Path Absence. The Vault KV leaf `cilium/hubble/cluster-config` remains empty during a health gate failure. Module `credential_cilium_hubble` depends on `kubeconfig_raw`, which depends on `data.talos_cluster_health.this`.
2. State Extraction. Command `terraform state pull` reads `talos_machine_secrets.client_configuration` from the GitLab HTTP backend. Variables `TF_HTTP_USERNAME` and `TF_HTTP_PASSWORD` MUST come from the Vault KV path `secret/parent-group-governance/terraform/state-backend`. The derived talosconfig and the state copy MUST reside outside the repository working tree. The derived talosconfig and the state copy MUST be deleted after the diagnosis.

### Item D. Guest Layer

1. Etcd Latency Signature. The count of `apply request took too long` in `talosctl logs etcd` measures etcd request latency. The count of `slow fdatasync` in the same log measures storage latency. A high count of slow requests together with a zero count of `slow fdatasync` falsifies the storage hypothesis.
2. Guest Pressure. Command `talosctl read` against `/proc/pressure/cpu`, `/proc/pressure/memory`, and `/proc/pressure/io` measures resource stall inside the guest. Values near zero falsify resource starvation as the cause of etcd latency.
3. Request Profile. Slow requests concentrated on large range responses (e.g., CRD listings) indicate a frame size defect when small requests succeed. The error `connection reset by peer` on apid proxy traffic between nodes corroborates a transport defect.

### Item E. MTU Verification

1. Guest Link MTU. Command `talosctl get links` reports the MTU of each guest interface.
2. Host Bridge MTU. The file `/sys/class/net/<tap>/mtu` reports the MTU of each tap device. The `mtu` element of `virsh net-dumpxml` reports the MTU of each libvirt bridge.
3. Acceptance Criteria. Every guest interface MUST report the bridge MTU. The count of `apply request took too long` MUST remain at zero after bootstrap completes. The Cilium agent route table MUST report `mtu 1400` for pod CIDR routes. Command `talosctl health` MUST pass every check.

## Section 4. References

1. Architecture decision record for this migration, stored at `documentation/architecture-decision-record/20260813_1630-clb-migration-to-talos-cilium.md`.
2. Sidero Labs. (2026). _Deploy Cilium CNI_. Retrieved from [https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium)
3. Cilium Authors. (2026). _Kubernetes Without kube-proxy_. Retrieved from [https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)
4. Cilium Authors. (2026). _LoadBalancer IP Address Management (LB IPAM)_. Retrieved from [https://docs.cilium.io/en/stable/network/lb-ipam/](https://docs.cilium.io/en/stable/network/lb-ipam/)
5. Sidero Labs. (2026). _Talos Provider_. Terraform Registry. Retrieved from [https://registry.terraform.io/providers/siderolabs/talos/latest](https://registry.terraform.io/providers/siderolabs/talos/latest)
6. Cilium Authors. (2024). _pkg/mtu/mtu.go_ (v1.16.5). Retrieved from [https://github.com/cilium/cilium/blob/v1.16.5/pkg/mtu/mtu.go](https://github.com/cilium/cilium/blob/v1.16.5/pkg/mtu/mtu.go)
