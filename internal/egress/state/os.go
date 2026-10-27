package state

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/trevor-vaughan/claude-riotbox/internal/egress/policy"
)

// LoadOS reads the OS plugins' groups from dir (docs/dev/os-contract.md),
// in name order: each subdirectory holding egress-hosts is a plugin
// (policy.OSGroup). A subdirectory with neither egress-hosts nor
// manifest.sh (lib/), or whose name starts with "_" or ".", is not one; a
// manifest.sh without egress-hosts is an error. dir "" has no plugins.
func LoadOS(dir string) ([]policy.GroupDef, error) {
	if dir == "" {
		return nil, nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var groups []policy.GroupDef
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, "_") || strings.HasPrefix(name, ".") {
			continue
		}
		// os.Stat, not e.IsDir: the shell registry's glob follows a symlinked plugin dir.
		info, err := os.Stat(filepath.Join(dir, name))
		if errors.Is(err, fs.ErrNotExist) {
			continue // dangling symlink
		}
		if err != nil {
			return nil, err
		}
		if !info.IsDir() {
			continue
		}
		path := filepath.Join(dir, name, "egress-hosts")
		data, err := os.ReadFile(path)
		if errors.Is(err, fs.ErrNotExist) {
			_, statErr := os.Stat(filepath.Join(dir, name, "manifest.sh"))
			if statErr == nil {
				return nil, fmt.Errorf("%s: an OS plugin needs egress-hosts beside its manifest.sh", path)
			}
			if !errors.Is(statErr, fs.ErrNotExist) {
				return nil, statErr
			}
			continue
		}
		if err != nil {
			return nil, err
		}
		g, err := policy.OSGroup(name, path, data)
		if err != nil {
			return nil, err
		}
		groups = append(groups, g)
	}
	return groups, nil
}

// OSConf is the OS plugins' groups as loaded at start.
func (d Dir) OSConf() string { return filepath.Join(d.Path(), "os.conf") }

// WriteOSGroups saves groups as os.conf, a [group NAME] section each.
func (d Dir) WriteOSGroups(groups []policy.GroupDef) error {
	var b strings.Builder
	for _, g := range groups {
		b.WriteString("[group " + g.Name + "]\n")
		for _, e := range g.Members {
			b.WriteString(e.String() + "\n")
		}
	}
	return WriteAtomic(d.OSConf(), []byte(b.String()))
}

// OSGroups is the OS plugins' groups as saved at start (os.conf); none
// when the file is missing, as for a session an older release started.
// Like agent.conf it is trusted, not re-validated: the state root is
// masked from the agent, so only riotbox writes it.
func (d Dir) OSGroups() ([]policy.GroupDef, error) {
	c, err := ReadConf(d.OSConf())
	if err != nil {
		return nil, err
	}
	if c.Strict != policy.StrictUnset || len(c.Items) > 0 {
		return nil, fmt.Errorf("%s: only [group] sections are allowed here", d.OSConf())
	}
	return c.Groups, nil
}
