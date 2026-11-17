package main

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"

	"platform/internal/clusterops"
	"platform/internal/libvirtops"
	"platform/internal/operatorops"
	"platform/internal/ui"
)

// newWorkstation returns the cluster workstation of the repository and of the process environment.
func (a *app) newWorkstation() clusterops.Workstation {
	return clusterops.Workstation{
		TenantsLayerDir: filepath.Join(a.terraform, "layers", "security-vault-downstream-tenants"),
		Operator:        operatorops.Config{WrapperDir: operatorops.DefaultWrapperDir, OwnerCode: libvirtops.ProjectCode},
		Getenv:          os.Getenv,
	}
}

// reportSession prints the nodes of session, and warns when the talosconfig lacks endpoints.
func (a *app) reportSession(session clusterops.Session) {
	if session.NodesErr != nil {
		a.out.Print(ui.Warn, "The talosconfig lacks endpoints, pass talosctl --endpoints: "+session.NodesErr.Error())
	}
	a.out.Print(ui.Info, fmt.Sprintf("Cluster %s/%s, nodes: %s", session.Target.Service, session.Target.Component,
		cmp.Or(strings.Join(session.Nodes, " "), "unresolved")))
}

// openClusterShell opens a shell whose KUBECONFIG and TALOSCONFIG point at the session files of the target of arg.
func (a *app) openClusterShell(ctx context.Context, arg string) error {
	session, err := a.newWorkstation().OpenSession(ctx, arg)
	if err != nil {
		return err
	}
	a.reportSession(session)
	a.out.Print(ui.Info, "Exit the shell to remove the session files.")
	env := clusterops.BuildShellEnv(os.Environ(), session.Dir, session.Target)
	return clusterops.RunSession(ctx, session.Dir, env, a.runClusterShell)
}

// reportClusterStatus prints the nodes and the pods of the target of arg, or of every target for all.
func (a *app) reportClusterStatus(ctx context.Context, arg string) error {
	ws := a.newWorkstation()
	coordinates, err := clusterops.ReadCoordinates(ctx, ws.TenantsLayerDir)
	if err != nil {
		return err
	}
	if arg != "all" {
		target, err := clusterops.ParseTarget(arg)
		if err != nil {
			return err
		}
		return a.printClusterStatus(ctx, ws, coordinates, target)
	}

	for _, target := range coordinates.ListTargets() {
		err := a.printClusterStatus(ctx, ws, coordinates, target)
		switch {
		case errors.Is(err, clusterops.ErrClusterConfigMissing):
			a.out.Print(ui.Info, "No cluster-config, the component runs on the VM runtime.")
		case err != nil:
			a.out.Print(ui.Warn, err.Error())
		}
	}
	return nil
}

// printClusterStatus prints the nodes and the pods of target through temporary session files.
func (a *app) printClusterStatus(ctx context.Context, ws clusterops.Workstation, coordinates clusterops.Coordinates, target operatorops.OperatorSubject) error {
	a.out.PrintDivider("=")
	a.out.Print(ui.Step, fmt.Sprintf("Cluster %s/%s", target.Service, target.Component))
	cred, err := ws.ReadTargetCredential(ctx, coordinates, target)
	if err != nil {
		return err
	}
	session, err := ws.CreateSession(ctx, target, cred)
	if err != nil {
		return err
	}
	a.reportSession(session)
	return clusterops.RunSession(ctx, session.Dir, nil, func(ctx context.Context, _ []string) error {
		for _, args := range [][]string{{"get", "nodes", "-o", "wide"}, {"get", "pods", "-A"}} {
			cmd := exec.CommandContext(ctx, "kubectl", append([]string{"--kubeconfig", session.KubeconfigPath(), "--request-timeout=10s"}, args...)...)
			cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
			err := cmd.Run()
			if err != nil {
				a.out.Print(ui.Warn, "kubectl "+strings.Join(args, " ")+": "+err.Error())
			}
		}
		return nil
	})
}

// runClusterShell runs $SHELL with env and reports the exit status of the shell as information.
// A caught SIGINT keeps platform alive for the removal of the session files, while exec resets the SIGINT disposition inside the shell.
func (a *app) runClusterShell(ctx context.Context, env []string) error {
	interrupts := make(chan os.Signal, 1)
	signal.Notify(interrupts, os.Interrupt)
	defer signal.Stop(interrupts)

	cmd := exec.CommandContext(ctx, cmp.Or(os.Getenv("SHELL"), "/bin/sh"))
	cmd.Env = env
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	err := cmd.Run()
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		a.out.Print(ui.Info, fmt.Sprintf("Session shell exited with status %d.", exitErr.ExitCode()))
		return nil
	}
	return err
}
