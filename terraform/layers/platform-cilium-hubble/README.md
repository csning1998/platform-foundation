# platform-cilium-hubble

The layer provisions the Talos cluster of Cilium and the Downstream Vault objects of the in-cluster trust chain.

## Section 1. Runbook: recovery after a state loss

A state loss is the removal of the remote state of the layer while the Downstream Vault objects of the layer remain.

A state loss occurs after a purge of the remote state without a preceding `terraform destroy`.

### Task A. Import the Kubernetes auth mount

The Kubernetes auth mount is the resource `module.vault_auth_cilium_hubble.vault_auth_backend.kubernetes`.

The path of the Kubernetes auth mount is `<cluster_name>-service-account-token-provider`, which resolves to `platform-foundation-cilium-hubble-service-account-token-provider`.

Terraform fails with `path is already in use` when the Downstream Vault contains the mount and the state does not.

The mount MUST be imported into the state before the first apply.

```bash
terraform import module.vault_auth_cilium_hubble.vault_auth_backend.kubernetes platform-foundation-cilium-hubble-service-account-token-provider
terraform apply
```

The Kubernetes auth roles, the PKI role, the policies, and the KV entry of the layer are overwritten by the apply and need no import.

Deleting the mount instead of importing the mount removes the Kubernetes auth roles of cert-manager and External Secrets Operator.
