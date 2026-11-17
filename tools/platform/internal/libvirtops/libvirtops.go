// Package libvirtops provides libvirt daemon socket readiness checks and resource management.
package libvirtops

import (
	"encoding/xml"
	"fmt"
	"os/exec"
	"strings"
	"time"

	libvirt "libvirt.org/go/libvirt"

	"platform/internal/config"
	"platform/internal/ui"
)

// ProjectCode defines the target resource prefix used to filter libvirt entities during purge operations.
const ProjectCode = config.ProjectCode

func hasProjectPrefix(name string) bool {
	return strings.HasPrefix(name, ProjectCode+"-")
}

var libvirtSockets = []string{"virtqemud.socket", "virtnetworkd.socket", "virtstoraged.socket"}

// domainXML defines the XML structure required to extract disk source file paths from virDomainGetXMLDesc output.
type domainXML struct {
	Devices struct {
		Disks []struct {
			Source struct {
				File string `xml:"file,attr"`
			} `xml:"source"`
		} `xml:"disk"`
	} `xml:"devices"`
}

// parseDiskPaths parses a virDomainGetXMLDesc XML document and extracts all defined disk source file paths.
// Malformed XML documents SHALL return an empty string slice.
func parseDiskPaths(xmlDesc string) []string {
	var parsed domainXML
	if err := xml.Unmarshal([]byte(xmlDesc), &parsed); err != nil {
		return nil
	}
	paths := make([]string, 0, len(parsed.Devices.Disks))
	for _, disk := range parsed.Devices.Disks {
		if disk.Source.File != "" {
			paths = append(paths, disk.Source.File)
		}
	}
	return paths
}

// listDiskPaths retrieves backing disk file paths associated with dom.
// Failures during virDomainGetXMLDesc execution SHALL return an empty string slice to allow execution continuation.
func listDiskPaths(dom *libvirt.Domain) []string {
	desc, err := dom.GetXMLDesc(0)
	if err != nil {
		return nil
	}
	return parseDiskPaths(desc)
}

// deleteBackingVolumes deletes target storage volumes at paths via their associated storage pools.
// Lookup errors and paths not managed as libvirt storage volumes SHALL be ignored.
func deleteBackingVolumes(conn *libvirt.Connect, paths []string, out *ui.Printer) {
	for _, path := range paths {
		vol, err := conn.LookupStorageVolByPath(path)
		if err != nil {
			continue
		}
		out.Print(ui.Task, "Deleting backing disk image: "+path)
		_ = vol.Delete(libvirt.STORAGE_VOL_DELETE_NORMAL)
		_ = vol.Free()
	}
}

// EnsureServices checks and starts required libvirt daemon sockets if they are inactive.
func EnsureServices(out *ui.Printer) error {
	out.Print(ui.Info, "Checking status of libvirt sockets...")

	for _, sock := range libvirtSockets {
		if exec.Command("systemctl", "is-active", "--quiet", sock).Run() == nil {
			out.Print(ui.OK, sock+" is already running.")
			continue
		}

		out.Print(ui.Warn, sock+" is not running. Attempting to start it...")
		if err := exec.Command("sudo", "systemctl", "start", sock).Run(); err != nil {
			return fmt.Errorf("libvirtops: failed to start %s: %w", sock, err)
		}
		out.Print(ui.OK, sock+" started successfully.")
		time.Sleep(2 * time.Second)
	}
	return nil
}

// ListActiveNetworkXML returns the XML document of every active network on qemu:///system. The XML of an
// inactive network lacks a DNS record which dnsmasq serves.
func ListActiveNetworkXML() ([]string, error) {
	conn, err := libvirt.NewConnect("qemu:///system")
	if err != nil {
		return nil, fmt.Errorf("libvirtops: connect to qemu:///system: %w", err)
	}
	defer func() { _, _ = conn.Close() }()

	networks, err := conn.ListAllNetworks(libvirt.CONNECT_LIST_NETWORKS_ACTIVE)
	if err != nil {
		return nil, fmt.Errorf("libvirtops: list networks: %w", err)
	}
	defer func() {
		for i := range networks {
			_ = networks[i].Free()
		}
	}()

	documents := make([]string, 0, len(networks))
	for i := range networks {
		desc, err := networks[i].GetXMLDesc(0)
		if err != nil {
			return nil, fmt.Errorf("libvirtops: read network XML: %w", err)
		}
		documents = append(documents, desc)
	}
	return documents, nil
}

// Purge forcefully destroys and deletes all domains, storage pools, volumes, and networks matching ProjectCode.
func Purge(out *ui.Printer) error {
	conn, err := libvirt.NewConnect("qemu:///system")
	if err != nil {
		return fmt.Errorf("libvirtops: connect to qemu:///system: %w", err)
	}
	defer func() { _, _ = conn.Close() }()

	out.Print(ui.Step, "Detecting and purging all resources with project_code = '"+ProjectCode+"'...")

	out.Print(ui.Step, "Purging Virtual Machines (Domains)...")
	domains, err := conn.ListAllDomains(libvirt.CONNECT_LIST_DOMAINS_ACTIVE | libvirt.CONNECT_LIST_DOMAINS_INACTIVE)
	if err != nil {
		return fmt.Errorf("libvirtops: list domains: %w", err)
	}
	for i := range domains {
		dom := &domains[i]
		name, err := dom.GetName()
		if err != nil || !hasProjectPrefix(name) {
			_ = dom.Free()
			continue
		}
		diskPaths := listDiskPaths(dom)
		out.Print(ui.Task, "Destroying and undefining VM: "+name)
		_ = dom.Destroy()
		_ = dom.UndefineFlags(libvirt.DOMAIN_UNDEFINE_NVRAM)
		deleteBackingVolumes(conn, diskPaths, out)
		_ = dom.Free()
	}

	out.Print(ui.Step, "Purging Storage Volumes and Pools...")
	pools, err := conn.ListAllStoragePools(libvirt.CONNECT_LIST_STORAGE_POOLS_ACTIVE | libvirt.CONNECT_LIST_STORAGE_POOLS_INACTIVE)
	if err != nil {
		return fmt.Errorf("libvirtops: list storage pools: %w", err)
	}
	for i := range pools {
		pool := &pools[i]
		name, err := pool.GetName()
		if err != nil || !hasProjectPrefix(name) {
			_ = pool.Free()
			continue
		}

		if vols, err := pool.ListAllStorageVolumes(0); err == nil {
			for j := range vols {
				vol := &vols[j]
				if volName, err := vol.GetName(); err == nil {
					out.Print(ui.Task, "Deleting volume: "+volName+" from pool "+name)
				}
				_ = vol.Delete(libvirt.STORAGE_VOL_DELETE_NORMAL)
				_ = vol.Free()
			}
		}

		out.Print(ui.Task, "Destroying and undefining pool: "+name)
		_ = pool.Destroy()
		_ = pool.Undefine()
		_ = pool.Free()
	}

	out.Print(ui.Step, "Purging Networks...")
	networks, err := conn.ListAllNetworks(libvirt.CONNECT_LIST_NETWORKS_ACTIVE | libvirt.CONNECT_LIST_NETWORKS_INACTIVE)
	if err != nil {
		return fmt.Errorf("libvirtops: list networks: %w", err)
	}
	for i := range networks {
		net := &networks[i]
		name, err := net.GetName()
		if err != nil || !hasProjectPrefix(name) {
			_ = net.Free()
			continue
		}
		out.Print(ui.Task, "Destroying and undefining network: "+name)
		_ = net.Destroy()
		_ = net.Undefine()
		_ = net.Free()
	}

	out.PrintDivider("")
	out.Print(ui.OK, "Libvirt resource purge complete.")
	out.PrintDivider("")
	return nil
}
