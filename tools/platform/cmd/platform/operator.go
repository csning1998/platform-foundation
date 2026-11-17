package main

import (
	"context"
	"fmt"
	"os"
	"syscall"

	"platform/internal/libvirtops"
	"platform/internal/operatorops"
)

// runLayerTerraform replaces the process with terraform, which withholds the JWT-SVID from every child but terraform.
func (a *app) runLayerTerraform(ctx context.Context, args []string) error {
	layerDir, err := os.Getwd()
	if err != nil {
		return fmt.Errorf("terraform: %w", err)
	}
	cfg := operatorops.Config{WrapperDir: operatorops.DefaultWrapperDir, OwnerCode: libvirtops.ProjectCode}
	inv, err := operatorops.PrepareTerraform(ctx, cfg, layerDir, args, os.Environ())
	if err != nil {
		return err
	}
	err = syscall.Exec(inv.Path, inv.Args, inv.Env)
	return fmt.Errorf("terraform: exec %s: %w", inv.Path, err)
}
