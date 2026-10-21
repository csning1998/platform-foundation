// Package terraformops reports the presence of Terraform layer directories.
package terraformops

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"platform/internal/ui"
)

// ReportCleanupStatus reports which of the specified Terraform layers, or of all configured layers, have a directory.
// The report deletes nothing, since every layer keeps its state in the GitLab HTTP backend.
func ReportCleanupStatus(terraformDir, target string, allLayers []string, out *ui.Printer) error {
	if target == "" {
		return fmt.Errorf("terraformops: no layer specified")
	}

	layers := []string{target}
	if target == "all" {
		out.Print(ui.Step, "Checking all configured Terraform layers...")
		layers = allLayers
	}

	var present, missing []string
	for _, layer := range layers {
		if _, err := os.Stat(filepath.Join(terraformDir, "layers", layer)); err != nil {
			missing = append(missing, layer)
			continue
		}
		present = append(present, layer)
	}

	if len(present) > 0 {
		out.Print(ui.Step, "Checking Terraform layer directories...")
		out.Print(ui.OK, "Terraform layer directories present: "+strings.Join(present, ", "))
	}
	for _, layer := range missing {
		out.Print(ui.Warn, "Terraform layer directory not found, skipping: "+filepath.Join(terraformDir, "layers", layer))
	}
	out.PrintDivider("")
	return nil
}
