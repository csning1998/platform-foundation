package config

import (
	"path/filepath"
	"testing"
)

func TestDiscoverPackerBases_SortsAndExcludesValues(t *testing.T) {
	dir := t.TempDir()
	mustMkdirAll(t, filepath.Join(dir, "distro"))
	mustMkdirAll(t, filepath.Join(dir, "services"))
	mustWriteFile(t, filepath.Join(dir, "distro", "ubuntu-24.pkrvars.hcl"), "")
	mustWriteFile(t, filepath.Join(dir, "distro", "values.pkrvars.hcl"), "")
	mustWriteFile(t, filepath.Join(dir, "services", "base-docker-harbor.pkrvars.hcl"), "")

	got, err := DiscoverPackerBases(dir)
	if err != nil {
		t.Fatalf("DiscoverPackerBases: %v", err)
	}
	want := []string{"base-docker-harbor", "ubuntu-24"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Errorf("DiscoverPackerBases = %v, want %v", got, want)
	}
}

func TestDiscoverTerraformLayers_ReturnsNilWhenDirMissing(t *testing.T) {
	got, err := DiscoverTerraformLayers(filepath.Join(t.TempDir(), "no-such-terraform-dir"))
	if err != nil {
		t.Fatalf("DiscoverTerraformLayers: %v", err)
	}
	if got != nil {
		t.Errorf("DiscoverTerraformLayers on missing dir = %v, want nil", got)
	}
}

func TestDiscoverPackerBases_HandlesPartialDirectories(t *testing.T) {
	cases := []struct {
		name  string
		setup func(t *testing.T, dir string)
		want  []string
	}{
		{
			name: "only distro exists",
			setup: func(t *testing.T, dir string) {
				mustMkdirAll(t, filepath.Join(dir, "distro"))
				mustWriteFile(t, filepath.Join(dir, "distro", "ubuntu-24.pkrvars.hcl"), "")
			},
			want: []string{"ubuntu-24"},
		},
		{
			name: "only services exists",
			setup: func(t *testing.T, dir string) {
				mustMkdirAll(t, filepath.Join(dir, "services"))
				mustWriteFile(t, filepath.Join(dir, "services", "base-docker-harbor.pkrvars.hcl"), "")
			},
			want: []string{"base-docker-harbor"},
		},
		{
			name:  "both missing",
			setup: func(t *testing.T, dir string) {},
			want:  nil,
		},
		{
			name: "values.pkrvars.hcl excluded from both distro and services",
			setup: func(t *testing.T, dir string) {
				mustMkdirAll(t, filepath.Join(dir, "distro"))
				mustMkdirAll(t, filepath.Join(dir, "services"))
				mustWriteFile(t, filepath.Join(dir, "distro", "values.pkrvars.hcl"), "")
				mustWriteFile(t, filepath.Join(dir, "services", "values.pkrvars.hcl"), "")
			},
			want: nil,
		},
		{
			name: "directory entry with matching suffix is skipped",
			setup: func(t *testing.T, dir string) {
				mustMkdirAll(t, filepath.Join(dir, "distro", "looks-like-a-base.pkrvars.hcl"))
				mustWriteFile(t, filepath.Join(dir, "distro", "real-base.pkrvars.hcl"), "")
			},
			want: []string{"real-base"},
		},
		{
			name: "bare suffix file yields empty base name",
			setup: func(t *testing.T, dir string) {
				mustMkdirAll(t, filepath.Join(dir, "distro"))
				mustWriteFile(t, filepath.Join(dir, "distro", ".pkrvars.hcl"), "")
			},
			want: []string{""},
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			c.setup(t, dir)
			assertDiscoverPackerBases(t, dir, c.want)
		})
	}
}

func assertDiscoverPackerBases(t *testing.T, dir string, want []string) {
	t.Helper()
	got, err := DiscoverPackerBases(dir)
	if err != nil {
		t.Fatalf("DiscoverPackerBases: %v", err)
	}
	if len(got) != len(want) {
		t.Fatalf("DiscoverPackerBases = %v, want %v", got, want)
	}
	for i := range got {
		if got[i] != want[i] {
			t.Fatalf("DiscoverPackerBases = %v, want %v", got, want)
		}
	}
}

func TestDiscoverTerraformLayers_HandlesEmptyAndMixedDirectories(t *testing.T) {
	t.Run("empty layers dir yields nil", func(t *testing.T) {
		dir := t.TempDir()
		mustMkdirAll(t, filepath.Join(dir, "layers"))

		got, err := DiscoverTerraformLayers(dir)
		if err != nil {
			t.Fatalf("DiscoverTerraformLayers: %v", err)
		}
		if got != nil {
			t.Errorf("DiscoverTerraformLayers on empty dir = %v, want nil", got)
		}
	})

	t.Run("files are not counted as layers", func(t *testing.T) {
		dir := t.TempDir()
		mustMkdirAll(t, filepath.Join(dir, "layers", "networking"))
		mustWriteFile(t, filepath.Join(dir, "layers", "README.md"), "")

		got, err := DiscoverTerraformLayers(dir)
		if err != nil {
			t.Fatalf("DiscoverTerraformLayers: %v", err)
		}
		if len(got) != 1 || got[0] != "networking" {
			t.Errorf("DiscoverTerraformLayers = %v, want [networking]", got)
		}
	})
}
