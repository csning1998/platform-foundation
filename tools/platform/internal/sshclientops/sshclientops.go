// Package sshclientops removes the SSH client material which foundation-libvirt-resources writes for the clusters of
// this repository: the identity key pair, the Host block file, the known_hosts file, and the Include directive.
package sshclientops

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"gitlab.com/csning1998-lab/terraform/terraform-provider-sshclient/sshops/include"

	"platform/internal/config"
	"platform/internal/ui"
)

// clusterPrefix requires a cluster suffix, which keeps the shared guest key id_<algorithm>_<ProjectCode> out of reach.
const clusterPrefix = config.ProjectCode + "-"

// clusterFileRe matches the identity key pair, the Host block file, and the known_hosts file of one cluster.
var clusterFileRe = regexp.MustCompile(`^(id_[a-z0-9]+_|ssh_|known_hosts_)` + regexp.QuoteMeta(clusterPrefix) + `[a-z0-9-]+(\.pub)?$`)

// Purge removes the Include directives which name a Host block file of a cluster, then the files of every cluster.
func Purge(home string, out *ui.Printer) error {
	sshDir := filepath.Join(home, ".ssh")
	out.Print(ui.Step, "Purging the SSH client material of '"+config.ProjectCode+"' clusters...")

	includePaths, err := listClusterIncludePaths(sshDir)
	if err != nil {
		return err
	}
	for _, path := range includePaths {
		out.Print(ui.Task, "Removing Include directive: "+path)
		if err := include.RemoveSSHIncludeDirective(home, path); err != nil {
			return fmt.Errorf("sshclientops: remove Include %s: %w", path, err)
		}
	}

	entries, err := os.ReadDir(sshDir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("sshclientops: read %s: %w", sshDir, err)
	}
	for _, entry := range entries {
		if entry.IsDir() || !clusterFileRe.MatchString(entry.Name()) {
			continue
		}
		out.Print(ui.Task, "Removing: "+filepath.Join(sshDir, entry.Name()))
		if err := os.Remove(filepath.Join(sshDir, entry.Name())); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("sshclientops: remove %s: %w", entry.Name(), err)
		}
	}
	out.Print(ui.OK, "SSH client material purge complete.")
	return nil
}

// listClusterIncludePaths returns the Include targets of sshDir/config which are Host block files of a cluster.
func listClusterIncludePaths(sshDir string) ([]string, error) {
	data, err := os.ReadFile(filepath.Join(sshDir, "config"))
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("sshclientops: read %s: %w", filepath.Join(sshDir, "config"), err)
	}
	var paths []string
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		directive, path, ok := strings.Cut(strings.TrimSpace(scanner.Text()), " ")
		path = strings.TrimSpace(path)
		if !ok || directive != "Include" || filepath.Dir(path) != sshDir {
			continue
		}
		if name := filepath.Base(path); strings.HasPrefix(name, "ssh_"+clusterPrefix) && clusterFileRe.MatchString(name) {
			paths = append(paths, path)
		}
	}
	return paths, scanner.Err()
}
