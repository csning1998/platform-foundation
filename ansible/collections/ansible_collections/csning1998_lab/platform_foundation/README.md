# Collection csning1998_lab.platform_foundation

This collection holds every Ansible role of `platform-foundation`. The roles build the platform images through Packer and configure the platform services after Terraform creates the guests.

## Section 1. Role Families

| Prefix         | Stage                                                      |
| :------------- | :--------------------------------------------------------- |
| `base_`        | Installs packages into a Packer image                      |
| `foundation_`  | Applies the common layer and the final cleanup of an image |
| `platform_`    | Configures a service on a running guest                    |
| `provision_`   | Configures a service after the platform stage completes    |
| `utils_`       | Serves other roles through `include_role`                  |
| `hypervisor_`  | Configures the physical hypervisor host                    |
| `utilities`    | Configures the interactive shell of a guest                |

## Section 2. Consumption

1. A consumer repository MUST reference a role by its fully qualified name, for example `csning1998_lab.platform_foundation.platform_postgres`.
2. A consumer repository MUST keep a role specific to the consumer in its own `ansible/roles` directory, since the `ansible-runner` module renders both `roles_path` and `collections_path` below the Ansible root of the caller.
3. A role MUST NOT hold a confidential value in its defaults or examples. A role reads a confidential value from Vault at runtime.

## Section 3. Variables

1. A variable which one role owns carries the role name as its prefix and resides in the defaults of that role.
2. A constant which several roles share resides in the defaults of `utils_common_defaults`, and each reader declares that role as a dependency in `meta/main.yaml`.
3. The caller MUST define the variables below in its own `group_vars`, since the values depend on the caller:

| Variable                      | Meaning                                                                                  |
| :---------------------------- | :--------------------------------------------------------------------------------------- |
| `project_code`                | Owner code of the caller, which names the Vault Proxy identity in messages               |
| `operator_vault_url`          | Operator Vault address, `VAULT_ADDR` of `vault-proxy-env` by default in `platform-foundation` |
| `operator_vault_ca_cert_path` | CA file of the operator Vault listener                                                   |
| `operator_vault_client_cert`  | Client certificate for the Vault Proxy, empty for a Vault without a Proxy                |
| `operator_vault_client_key`   | Client key for the Vault Proxy, empty for a Vault without a Proxy                        |
