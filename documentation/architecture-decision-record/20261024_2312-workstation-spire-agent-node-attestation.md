# ADR: Workstation SPIRE Agent Node Attestation

## Section 1. Executive Summary and Final Verdict

1. **Decision Status**: The attestor selection for the two SPIRE Agents of the operator workstation is open. This record holds the discussion of 2026-10-24. The final verdict MUST wait until every condition in Section 4 is satisfied.
2. **Current Constraint**: Both workstation agents attest with the `join_token` node attestor. A workstation agent with an expired agent SVID cannot attest again without a new join token. A workstation shutdown longer than the agent SVID lifetime, one hour for the Parent agent and four hours for the Child agent, therefore requires one forced playbook run per expired agent.
3. **Proposed Direction**: The Child agent of the workstation SHOULD move to the `x509pop` node attestor, which the SPIRE Child already enables. The Parent agent of the workstation retains `join_token` until the Bastion Vault provides a node attestation PKI.
4. **Cost of the Proposed Direction**: The `x509pop` attestor requires a node private key on the workstation disk for the lifetime of the node certificate. The window in which stolen agent data remains usable grows from four hours to the node certificate lifetime.

## Section 2. Technical Rationale and Architectural Design

### Item A. Incident of 2026-10-24

The workstation agent of the SPIRE Parent rotated the agent SVID for the last time at 2026-10-22 18:00:46 +0800. The rotated agent SVID expired at 2026-10-22 19:00:46 +0800. The workstation agent of the SPIRE Child held an agent SVID with an expiry of 2026-10-22 20:26:34 +0800. The workstation was shut down at 2026-10-22 18:07:58 +0800. The workstation booted again at 2026-10-23 04:55:50 +0800.

After the boot, each agent started node attestation, because the stored agent SVID had expired. The configured join token had already been consumed by the first attestation. Each SPIRE server rejected every attempt with `join token was not provided`. The agent creates the Workload API socket only after a successful attestation. Consequently, the `spire-fetch-*` wrappers failed. The `terraform plan` of `provision-spire-child` failed at the operator login.

### Item B. Agent SVID Lifetime

Role `platform_spire_parent` sets `platform_spire_parent_default_svid_ttl` to `1h` in `defaults/main.yaml`. Template `server.conf.j2` does not set `agent_ttl`. The journal of the Parent agent records an agent SVID lifetime of one hour.

The SPIRE Child deploys chart `spire-nested` at version `0.30.2`. Layer `provision-spire-child` sets neither `agentTTL` nor `defaultX509SvidTTL`. The chart default of `agentTTL` is empty. An empty `agentTTL` selects the chart default `defaultX509SvidTTL` of `4h`. The journal of the Child agent records an agent SVID rotation interval of about 110 minutes. The last rotation before the shutdown occurred at 2026-10-22 16:26:34 +0800, four hours before the expiry in Item A.

Agent SVID rotation requires a valid agent SVID, because the agent authenticates the rotation request with the current agent SVID.

### Item C. Recovery Path under `join_token`

Module `ansible-runner` invokes the playbook only after the creation or the update of `local_file.inventory`. A forced replacement of `local_file.inventory` therefore invokes the playbook again. Role `utils_spire_agent` detects the failed health check in Step D1. Role `utils_spire_agent` then generates a new join token in Block E. The recovery of 2026-10-24 applied the following replacements in order:

1. Layer `provision-spire-parent` replaced `module.ansible_operator_identity.local_file.inventory`.
2. Layer `provision-spire-child` replaced `module.workstation_child_agent.local_file.inventory`.

The order is fixed, because layer `provision-spire-child` obtains the operator JWT-SVID from the workstation agent of the SPIRE Parent. Each regenerated join token produces a new agent SPIFFE ID. Section 3 Item B of `documentation/architecture/platform-spire-parent-frontend.md` records the consequence for workload entries.

### Item D. Scope Conflict with the Bootstrap ADR

Section 1 of `20260830_1530-spire-parent-bootstrap-security-posture.md` restricts the `join_token` node attestor to the bootstrap of the SPIRE Parent host. The same section prohibits `join_token` as the enrollment path for other consumer hosts. The workstation agent of the SPIRE Parent uses `join_token` as the enrollment path. The current state of the workstation agent of the SPIRE Parent deviates from the bootstrap ADR. The bootstrap ADR does not govern the SPIRE Child, and Section 11 Item A of `documentation/architecture/platform-spire-parent-frontend.md` permits `join_token` on the SPIRE Child.

### Item E. Attestor Availability per Server

The SPIRE Child enables both `join_token` and `x509pop` in `provision-spire-child/main.tf`. The `x509pop` attestor of the SPIRE Child is configured in `externalPKI` mode. The CA bundle of the `x509pop` attestor is the intermediate CA of mount `pki-spire-node` in the Downstream Vault.

Layer `security-vault-downstream-pki` declares one node role per owner code in `owner-pki.tf`, including `platform-foundation`. Each node role issues client certificates with `ec` keys of 256 bits. Each node role restricts the common name to the pattern `<owner>-*.<stage domain>`. Each node role sets a default TTL of 30 days and a maximum TTL of 90 days.

The SPIRE Parent enables only `join_token` and `k8s_psat` in `server.conf.j2`. The Downstream Vault trusts the JWT-SVIDs of the SPIRE Parent. A node certificate for the Parent agent MUST NOT originate from the Downstream Vault, because an expired Parent agent blocks the operator login which the certificate renewal requires. The Bastion Vault is the only issuer outside the dependency cycle.

## Section 3. Attack Surface Comparison

### Item A. Comparison by Threat

| Threat                                       | `join_token`                                                                                                       | `x509pop`                                                                                                                  |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| Theft of the agent data during host downtime | The stolen agent SVID remains usable for at most one hour on the SPIRE Parent and four hours on the SPIRE Child.   | The stolen node key remains usable until the node certificate expires.                                                     |
| Compromise of the running host               | The attacker keeps the identity through agent SVID rotation.                                                       | The attacker keeps the identity through agent SVID rotation.                                                               |
| Exposure of the attestation credential       | Each recovery generates a join token. Step E3 of `utils_spire_agent` writes each join token to the operator Vault. | Recovery does not generate a credential.                                                                                   |
| Workload entries after a new attestation     | Each new join token produces a new agent ID. Every workload entry requires registration again.                     | The agent ID embeds the certificate fingerprint. A node alias with a subject CN selector keeps every workload entry valid. |
| Revocation                                   | The consumed join token does not require revocation. The agent identity requires an agent ban on the SPIRE server. | Revocation requires an agent ban on the SPIRE Child or the expiry of the node certificate.                                 |

### Item B. Open Questions on the Attack Surface

1. The revocation behavior of the `x509pop` attestor in `externalPKI` mode MUST be verified against the SPIRE documentation. The verification MUST cover the agent ban and the CRL support.
2. The networks with a route to the Child agent endpoint `172.16.126.252:443` MUST be enumerated. The enumeration bounds the locations at which a stolen node key is usable.
3. The disk encryption state of the workstation MUST be recorded.
4. The identity for the node certificate renewal MUST be determined. A renewal through the Downstream Vault depends on the operator login through the Parent agent.
5. The common name of the workstation node certificate MUST be determined within the pattern `platform-foundation-*.<stage domain>`. The common name MUST NOT collide with the node names of platform virtual machines.
6. The attestor of the virtual machine agents on the SPIRE Child MUST be confirmed. Section 11 Item A of `documentation/architecture/platform-spire-parent-frontend.md` names `join_token`. The comment on `nodeAttestor` in `provision-spire-child/main.tf` names node certificates.

## Section 4. Conditions for Attack Surface Reduction

### Item A. Child Agent of the Workstation

1. The node certificate lifetime MUST exceed the longest planned shutdown of the workstation.
2. The node certificate lifetime MUST NOT exceed the theft window which the owner accepts.
3. A renewal schedule MUST renew the node certificate during the online periods of the workstation.
4. The node private key MUST be readable by root alone with mode `0600`.
5. The node private key MUST carry the SELinux label of the agent data directory.
6. A node alias MUST select the subject CN of the workstation node certificate.
7. Every workload entry of the workstation operators MUST reference the node alias as the parent ID.
8. The revocation path in Section 3 Item B MUST be verified before the migration.
9. A runbook MUST describe the recovery after the expiry of the node certificate.

### Item B. Parent Agent of the Workstation

1. `parent-group-governance` MUST provide a node attestation PKI in the Bastion Vault.
2. The SPIRE Parent MUST enable the `x509pop` node attestor with the CA of the Bastion node attestation PKI.
3. Every condition of Item A MUST apply to the Parent agent.

### Item C. Interim State

Both workstation agents retain `join_token` until the conditions of Item A are satisfied. A workstation shutdown longer than the agent SVID lifetime of an agent requires the recovery path of Section 2 Item C for that agent. The cost of the interim state is one forced playbook run per agent after each long shutdown.
