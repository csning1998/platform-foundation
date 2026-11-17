# Platform Foundation Lexicon

This document records the naming conventions which are specific to the Terraform layers, the Terraform modules, and the Ansible roles of `platform-foundation`.

## Section 1. Scope and Precedence

1. The organization naming standard `planning/architecture-naming-standard.md` governs every naming axis which the organization naming standard defines.
2. This document MUST NOT redefine a rule of the organization naming standard.
3. A conflict between this document and the organization naming standard MUST be resolved in favor of the organization naming standard.
4. This document MUST name only identifiers which exist in the code.
5. `planning/To-do-list.md` tracks every point at which the code deviates from the organization naming standard.

The following rules of the organization naming standard apply most often in this repository.

| Naming axis                        | Rule                                                                                                                                                   | Source in the organization naming standard |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------ |
| Any name                           | A name MUST NOT repeat a qualifier which the namespace already implies.                                                                                | Section 3 Item A                           |
| Resource label, output, call label | A name MUST NOT include the owner code or a kind qualifier.                                                                                            | Section 3 Item B                           |
| Module call label                  | A call label MUST equal the module name with hyphens converted to underscores. A second call of one module MUST use the form `<call label>_<subject>`. | Section 5 Item C                           |
| Output                             | An output name MUST follow the form `<subject>_<attribute>`. A new output MUST NOT repeat the subject which the layer name already states.             | Section 5 Item D                           |
| Vault instance noun                | The Vault instance nouns are `bastion` and `downstream`. The noun `production` MUST name the stage only.                                               | Section 4 Item B and Item C                |

The call label of module `terraform-layer-context` is `terraform_layer_context`. The call label of an `orchestrate` module equals the module name, for example `linux_talos_cluster`. Both rules come from `planning/decisions.md`, entry `kvm-provisioning` module categories.

## Section 2. Layer Locals

1. A local which stores a value owned by another layer MUST begin with the qualifier of the source.
2. The qualifier `foundation_` MUST mark a value read from `foundation-libvirt-resources`, for example `foundation_kv_paths` and `foundation_project_code`.
3. The qualifier `downstream_` MUST mark a value which describes the Downstream Vault, for example `downstream_kv_paths` and `downstream_vault_endpoint`.
4. A local which stores a value owned by the layer itself MUST NOT begin with the subject of the layer, since the subject is implied by the layer namespace.
5. A runtime selection boolean MUST use the form `is_runtime_<runtime>`, for example `is_runtime_talos`.
6. The local `_state_base` MUST contain the base address of the GitLab Terraform state backend. The local `_state_base` MUST read the variable `gitlab_terraform_state_base`.
7. A SPIFFE trust domain MUST be spelled `spiffe_trust_domain` in a Terraform identifier.
8. A workload SPIFFE ID MUST be spelled `spiffe_workload_id` in a Terraform identifier.
9. The Vault Agent identity MUST be spelled `security_vault_agent_identity` in a Terraform identifier.
10. A key of the Ansible extra variables MUST equal the variable name which the receiving role reads, for example `spire_trust_domain`.
11. The term `fronted` MUST denote a segment which the HAProxy tier serves, as in `fronted_segments`.

## Section 3. Runtime Partition

A dual runtime layer is a layer which supports both the generic runtime and the Talos runtime.

1. A dual runtime layer MUST contain the declarations of the generic runtime in `runtime-generic.tf`.
2. A dual runtime layer MUST contain the declarations of the Talos runtime in `runtime-talos.tf`.
3. Every resource, module, data source, and ephemeral resource in a runtime file of a dual runtime layer MUST declare a `count` conditioned on `local.is_runtime_talos`.
4. A dual runtime layer MUST export the output `runtime` with the fields `name` and `kubernetes_native`.
5. A dual runtime layer MUST export both `talos_cluster` and `generic_cluster`.
6. Each of the objects `talos_cluster` and `generic_cluster` of a dual runtime layer MUST contain the field `enabled`.
7. The fields of the object of the unselected runtime MUST be null, because Terraform does not persist an output whose whole value is null.
8. A single runtime layer MAY contain the declarations of the runtime in the runtime file of the runtime.
9. A single runtime layer MUST export only the object of the runtime, either `talos_cluster` or `generic_cluster`.

## Section 4. Module Families

1. The name of a module under `terraform/modules/kubernetes-addons` MUST state the delivery method through the prefix.
2. The prefix `helm-chart-<chart>` MUST mark a module which delivers a Helm chart.
3. The prefix `manifest-<workload>` MUST mark a module which declares Kubernetes resources directly.
4. The modules under `terraform/modules/kvm-provisioning` MUST belong to one of the categories `configure`, `orchestrate`, and `helpers`.
5. `planning/decisions.md` defines the three categories in the entry `kvm-provisioning` module categories.

## Section 5. Ansible

1. A role name MUST begin with one of the tier prefixes `foundation_`, `hypervisor_`, `base_baremetal_`, `base_docker_`, `base_kubernetes_`, `platform_`, `provision_`, and `utils_`.
2. The role `base_docker` contains the Docker engine setup which every `base_docker_<service>` role requires.
3. The role `utilities` contains the shell setup of a guest.
4. The roles `base_docker` and `utilities` are the two role names without a tier prefix.
5. A variable in `defaults/main.yaml` or `vars/main.yaml` of a role MUST begin with the role name.
6. The inventory file of a cluster MUST be named after the field `ansible_inventory` of the catalog identity of the cluster.
