# ADR: SPIRE Parent Bootstrap Security Posture

## Section 1. Executive Summary and Final Verdict

1. **Bind Address Topology**: `spire-server` MUST bind `bind_address` to the node's own HostOnly private-tier IP (`module.context.svc_network.node_ips`), not to `0.0.0.0` and not to the service VIP.
2. **Node Attestor Scope**: The `join_token` NodeAttestor is a bootstrap-only mechanism, valid for the SPIRE Parent's own host during initial trust-bundle establishment. It MUST NOT be treated as the enrollment path for other consumer hosts.
3. **Root CA Trust State**: SPIRE Server self-signs its own root CA. This is a deliberate interim state, not an oversight. A Vault-backed `upstreamauthority` plugin replaces the self-signed root in a later change, without requiring re-attestation of already-registered workloads.
4. **Bastion Vault JWT Mount Naming**: The auth backend mount that will front SPIRE's OIDC discovery provider MUST use the fully-qualified, unique name `platform-foundation-spire-parent-jwt-svid-provider`, never the bare name `jwt`. ACL grants scoped to `jwt` would match any future auth mount whose path begins with that string.

## Section 2. Technical Rationale and Architectural Design

### Item A. Bind Address Topology

`provision-cilium-frontend` fronts every baremetal and VM service in the catalog, SPIRE Parent included, through selector-less Kubernetes Services and Endpoints. Cilium's L2 announcement owns the VIP address. The VIP is never assigned to any interface on the backend node itself. A service that binds to its own VIP fails to start with `EADDRNOTAVAIL` since the local kernel has no route to claim that address. `bind_address` MUST therefore resolve to the node's real HostOnly IP, sourced from `layer-context`'s `svc_network.node_ips` and threaded through Terraform's `ansible_template_config` as `spire_parent_node_ip`. Binding to `0.0.0.0` would work but exposes the registration and node APIs on every interface of the VM, including the NAT egress interface. Binding to the HostOnly IP confines exposure to the internal service network Cilium already gates.

### Item B. Node Attestor Scope

`NodeAttestor "join_token"` accepts any caller presenting a valid, single-use join token generated out-of-band via `spire-server token generate`. This plugin authenticates the SPIRE Parent host to itself during initial bootstrap, where no other attestation mechanism yet exists. Widening this to a general enrollment path for other hosts would let any holder of a leaked token attest as an arbitrary node. Consumer host enrollment uses a distinct, per-host attestor (a future change) rather than reusing this bootstrap token.

### Item C. Root CA Trust State

Vault's `upstreamauthority/vault` plugin, once configured, signs SPIRE's Intermediate CA against Bastion Vault's `pki_inter` mount, replacing the self-signed root as the trust anchor. SPIRE's SVID rotation semantics preserve existing workload identities across this transition without forcing re-attestation since the bundle rotation propagates through the existing trust bundle distribution mechanism. The self-signed interim state is bounded in scope. It signs SVIDs for the SPIRE Parent's own bootstrap workloads only, none of which are yet registered.

### Item D. Bastion Vault JWT Mount Naming

Vault ACL glob matching applies only at the final path segment. A rule granting `sudo`/`delete` against `sys/auth/jwt` or a trailing-glob `sys/mounts/auth/jwt*` matches any future auth backend whose path is prefixed with `jwt` (for example `jwt-prod` or `jwt-legacy`), letting `terraform-admin-policy` tune or destroy backends outside SPIRE's ownership. The existing `gitlab-saas-ci-job-jwt-provider` grants avoid this by using the backend's full, unique name. `platform-foundation-spire-parent-jwt-svid-provider` follows the same convention. No trailing glob is required since `platform-foundation-spire-parent-jwt-svid-provider` is already the complete, unique backend name.
