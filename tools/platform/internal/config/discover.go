package config

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// DiscoverPackerBases scans packerDir/distro and packerDir/services for *.pkrvars.hcl files,
// excluding values.pkrvars.hcl, and returns sorted base identifiers.
func DiscoverPackerBases(packerDir string) ([]string, error) {
	var bases []string
	for _, sub := range []string{"distro", "services"} {
		entries, err := os.ReadDir(filepath.Join(packerDir, sub))
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("config: read %s: %w", filepath.Join(packerDir, sub), err)
		}
		for _, entry := range entries {
			name := entry.Name()
			if entry.IsDir() || !strings.HasSuffix(name, ".pkrvars.hcl") || name == "values.pkrvars.hcl" {
				continue
			}
			bases = append(bases, strings.TrimSuffix(name, ".pkrvars.hcl"))
		}
	}
	sort.Strings(bases)
	return bases, nil
}

// DiscoverTerraformLayers lists subdirectories within terraformDir/layers and returns
// a lexicographically sorted slice of layer identifiers.
func DiscoverTerraformLayers(terraformDir string) ([]string, error) {
	entries, err := os.ReadDir(filepath.Join(terraformDir, "layers"))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("config: read %s/layers: %w", terraformDir, err)
	}

	var layers []string
	for _, entry := range entries {
		if entry.IsDir() {
			layers = append(layers, entry.Name())
		}
	}
	sort.Strings(layers)
	return layers, nil
}
