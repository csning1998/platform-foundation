# ADR: CIDR Address-Space Parameterization in `service-catalog`

## Section 1. Executive Summary and Final Verdict

1. **Address-Space Parameterization**: The `network_baseline` configuration schema SHALL incorporate three optional parameters, `cidr_subnet_bits` (default `8`), `cidr_nat_offset` (default `124`), and `cidr_index_max` (default `248`). These parameters replace hardcoded constants within `service-catalog/locals.tf` and `service-catalog/variables.tf`. Default values preserve exact behavioral equivalence for all existing deployments.
2. **Identifier Taxonomy Standardization**: Network field identifiers MUST conform to standardized root prefixes.
    - `cidr_`: address-space and subnet allocation parameters (`cidr_block`, `cidr_subnet_bits`, `cidr_nat_offset`, `cidr_index_max`, `cidr_index`).
    - `host_`: host position offsets within an allocated subnet (`host_vip_offset`).
    - `nat_`: the paired NAT subnet and interface (`nat_gateway`, `nat_cidr_block`, `nat_cidr_index`, `nat_dhcp`, `nat_mac`).
    - `global_`: platform-wide singleton constants (`global_mac_prefix`, `global_mtu`, `global_mss`).
3. **Post-Apply State Immutability**: The parameter triplet (`cidr_block`, `cidr_subnet_bits`, `cidr_nat_offset`) defines every `libvirt_network` address space. A post-apply modification of any of the three forces destruction and recreation of every `libvirt_network` resource. Operators MUST treat these three parameters as immutable infrastructure attributes after the initial deployment.
4. **Domain Expansion Strategy**: Range capacity under default parameters exhausts at 125 services per domain. Multi-domain expansion SHALL allocate discrete `/16` blocks within RFC 1918 Class B space (`172.16.0.0/12`, second octet range `16` through `31`, offering up to 16 independent domains). Each domain MUST run as a separate module invocation. An in-module domain lookup table and an IPv6 transition are both explicitly rejected since IPv6 operational overhead is disproportionate to current fleet scale (14 to 20 active services against a 2,000-service multi-domain ceiling).
5. **Purge of Unused Local Variables**: The `hypervisor-kvm` module locals `nat_ip`, `nat_ip_cidr`, `tier_nat_prefixes`, and `ip_md5_hash` SHALL be purged. The target rendering template `network_config.tftpl` configures the NAT interface through DHCP (`dhcp4: true`) and does not reference any static NAT addressing variable.

## Section 2. Technical Rationale and Architectural Design

### Item A. Address-Space Parameterization and Subnet Indexing Math

Subnet allocations are evaluated through standard IP functions.

- **HostOnly Subnet**: calculated as `cidrsubnet(network_baseline.cidr_block, cidr_subnet_bits, cidr_index)`.
- **Paired NAT Subnet**: calculated as `cidrsubnet(network_baseline.cidr_block, cidr_subnet_bits, cidr_index - cidr_nat_offset)`.

```text
[ Index 0 ]        Reserved for Platform Default Network
[ Index 1..124 ]   Allocated to Paired NAT Subnets (cidr_index - cidr_nat_offset)
[ Index 125..248 ] Valid Range for Component HostOnly Subnets (cidr_index)
```

The valid lower bound for `cidr_index` is `cidr_nat_offset + 1` (125 under default values). This lower bound guarantees that the paired NAT subnet index remains `>= 1` while reserving index `0` for the platform's default network. The upper bound `cidr_index_max` (248) is inclusive and enforces non-overlapping separation between the HostOnly range and the NAT range; a component MAY declare `cidr_index = 248`, pairing to NAT index `124`, the top of the NAT range and a value no HostOnly component ever uses directly. The valid allocation range for `cidr_index` under default settings MUST be strictly bounded within `[125, 248]`. A second, independent ceiling also applies: `cidr_index_max` MUST remain strictly below `2^cidr_subnet_bits` since `cidrsubnet()`'s `netnum` argument cannot exceed `2^newbits - 1` (255 under the default `cidr_subnet_bits = 8`). `foundation-libvirt-resources`, `kvm-foundation-resources`, and `service-catalog` each declare a `validation` block on `network_baseline` enforcing both ceilings together.

### Item B. Dual-NIC Topology Design Constraint

Every service virtual machine MUST maintain a two-interface separation.

- **HostOnly Interface**: assigned through `cidr_index`, for internal inter-service communication.
- **NAT Interface**: assigned through `cidr_index - cidr_nat_offset`, for egress internet connectivity.

The dual-NIC architecture allows administrative disconnection of the external egress path without disrupting internal inter-service routing. Implementations MUST NOT consolidate these two distinct interfaces into a single network topology.

### Item C. Provider Immutability Failure Modes

Modifying a network topology attribute on live infrastructure triggers known failure modes within the `dmacvicar/libvirt` provider.

1. **State Read-Back Inconsistency**: a call to `virNetworkDefineXML()` on an active network updates persistent storage, but an unflagged `virNetworkGetXMLDesc()` call returns the running in-memory state instead, causing a Terraform state drift detection failure for DNS host entries.
2. **Non-Deterministic Evaluation Order**: an unordered `for_each` map iteration induces a sequence mismatch between the live libvirt configuration and the Terraform execution plan during a multi-resource change.
3. **Cloud-Init Lifecycle Decoupling**: the `libvirt_volume.cloud_init_iso` resource lacks an in-place update capability. Recreating the ISO does not trigger network reconfiguration on an existing OS disk instance since the instance's cached `/var/lib/cloud/` metadata blocks the reconfiguration.

Since these three provider constraints cannot be mitigated through HCL abstraction, the parameter triplet (`cidr_block`, `cidr_subnet_bits`, `cidr_nat_offset`) MUST remain frozen after the initial apply. Topology expansion on an existing environment SHALL require either explicit `virsh net-update` manual intervention or the deployment of an independent `/16` domain.

### Item D. NAT Addressing Architecture

The NAT interface template `hypervisor-kvm/templates/network_config.tftpl` executes DHCP client initialization (`dhcp4: true`). The dynamic address pool boundaries (`.100` through `.199`) generated in `service-catalog/locals.tf` are assigned directly to the `libvirt_network` DHCP configuration in `kvm-foundation-resources/resources.tf`.

The calculated static NAT locals `nat_ip` and `nat_ip_cidr` were unreferenced by any template, and this change removes both. Static NAT addressing remains restricted to `hypervisor-kvm-lb`, where `nat_ip_cidr` is explicitly consumed by `network_config_lb.tftpl`.

### Item E. Scope of `global_mac_prefix`

The `network_baseline.global_mac_prefix` attribute MUST be consumed exclusively by `ha-service-kvm-central-lb` and `lb-interface-planner`, to calculate offset-based deterministic MAC addresses across a high-availability node set.

The generic instance module `hypervisor-kvm` SHALL generate its own node MAC addresses (`nat_mac`, `hostonly_mac`) from an MD5 digest of the node IP appended to the KVM OUI prefix (`52:54:00`). This separation prevents a `global_mac_prefix` modification from triggering a fleet-wide VM recreation.

### Item F. Collision Risk Analysis on MD5 Truncated MACs

`nat_mac` and `hostonly_mac` derive from the same `md5(node_config.ip)` digest through disjoint byte ranges (bytes 0-2 for `nat_mac`, bytes 3-5 for `hostonly_mac`), each a distinct 24-bit slice. `nat_mac` values across a node set form one 24-bit collision population and `hostonly_mac` values form a second, independent population; the birthday-paradox threshold below applies separately to each. Constrained by the 24-bit space of the `52:54:00` OUI, the birthday-paradox collision threshold at 50 percent probability evaluates to approximately 4,823 entries in either population.

$$p(n) \approx 1 - \exp\left(-\frac{n^2}{2k}\right) \quad \text{where } k = 2^{24} = 16{,}777{,}216$$

Current operational scale, on the order of dozens of nodes, presents negligible collision probability. `resource "terraform_data" "node_mac_uniqueness"` in `hypervisor-kvm/resources.tf` declares a `lifecycle.precondition` asserting `nat_mac` and `hostonly_mac` uniqueness across the nodes declared in one module call, blocking `terraform plan` and `terraform apply` on a collision. This precondition is scoped to a single module invocation and cannot detect a cross-layer collision between two different services' node sets. A platform-wide assertion would require aggregating every layer's `nodes_config` through a shared registry, and remains future work should the platform approach the 4,823-node threshold.

### Item G. Identifier Naming Taxonomy and Governance

Network field identifiers MUST conform to the semantic domains and naming rules defined below.

| Root prefix | Semantic domain                               | Field identifiers                                                                                                           | Origin / scope                                           |
| ----------- | --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| `cidr_`     | Third-octet subnet selection math             | `cidr_block`, `cidr_subnet_bits`, `cidr_nat_offset`, `cidr_index_max`, `cidr_index`                                         | `network_baseline` / `service_catalog` component         |
| `host_`     | Fourth-octet offset within a HostOnly subnet  | `host_vip_offset`                                                                                                           | `network_baseline`                                       |
| `nat_`      | Paired NAT subnet and interface configuration | `nat_gateway`, `nat_cidr_block`, `nat_cidr_index`, `nat_dhcp`, `nat_mac`                                                    | `service-catalog/locals.tf` / `hypervisor-kvm/locals.tf` |
| `global_`   | Platform-wide singleton constants             | `global_mac_prefix`, `global_mtu`, `global_mss`                                                                             | `network_baseline`                                       |
| (none)      | Resource identity and DNS metadata            | `cluster_name`, `bridge_name_host`, `bridge_name_nat`, `hash_prefix`, `interface_alias`, `hostonly_mac`, `hostonly_ip_cidr` | Computed local outputs                                   |
| (component) | Local component-level configuration           | `ip_range` (`start_ip`, `end_ip`), `ports` (`frontend_port`, `backend_port`)                                                | Component input schema                                   |

The five governance rules for field identifiers follow.

1. **Subnet selection**: a parameter that determines a `/24` subnet boundary MUST use the `cidr_` prefix.
2. **Host positioning**: a parameter that defines a host offset within a HostOnly subnet MUST use the `host_` prefix.
3. **NAT domain**: a parameter associated with the paired NAT subnet or interface MUST use the `nat_` prefix.
4. **Global constants**: a singleton attribute applicable across every node and subnet MUST use the `global_` prefix.
5. **Word order**: sibling attributes sharing one root prefix MUST follow the structural pattern `<root>_<subject>_<attribute>`.
