# Changelog

The collection version follows the SemVer tag of `platform-foundation`, and the release of that tag records each change.

## Section 1. Initial Contents

1. The collection gathers every role of `platform-foundation` under the namespace `csning1998_lab.platform_foundation`.
2. Playbooks and roles reference a role of the collection by its fully qualified name.
3. The role constants of the former `group_vars/all` reside in role defaults with the role name as prefix, and `utils_common_defaults` holds the constants which several roles share.
4. `platform_vault` and `provision_vault_downstream` write the emergency init file to a role variable anchored at `inventory_dir`.
