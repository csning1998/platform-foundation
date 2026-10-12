package main

import (
	"platform/internal/config"
	"platform/internal/vaultops"
)

func (a *app) newVaultPaths() vaultops.Paths {
	caCert := ""
	if a.env != nil {
		caCert = a.env.GetExpanded(config.KeyBastionVaultCACert)
	}
	return vaultops.NewPaths(a.root, a.ansibleDir, a.terraform, a.home, a.resolveBastionVaultAddr(), caCert)
}

// Returns the explicitly injected bastion address or falls back to BASTION_VAULT_ADDR from .env.
func (a *app) resolveBastionVaultAddr() string {
	if a.bastionVaultAddr != "" {
		return a.bastionVaultAddr
	}
	if a.env != nil {
		return a.env.GetExpanded(config.KeyBastionVaultAddr)
	}
	return ""
}

func getConfiguredPackerBases(env *config.Env) []string {
	return splitWhitespaceFields(env.Get(config.KeyAllPackerBases))
}

func getConfiguredTerraformLayers(env *config.Env) []string {
	return splitWhitespaceFields(env.Get(config.KeyAllTerraformLayers))
}

func splitWhitespaceFields(s string) []string {
	var out []string
	field := ""
	for _, r := range s {
		if r == ' ' || r == '\t' {
			if field != "" {
				out = append(out, field)
				field = ""
			}
			continue
		}
		field += string(r)
	}
	if field != "" {
		out = append(out, field)
	}
	return out
}
